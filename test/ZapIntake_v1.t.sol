// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {ZapIntake} from "@harborzap/zap/upgradeable/base/ZapIntake.sol";
import {IZapErrors} from "@harborzap/interfaces/IZapErrors.sol";

import {MockERC20} from "@harborzap-test/mock/MockERC20.sol";

/// @notice Harness exposing the internal `ZapIntake` library functions so their guards can be unit
///         tested directly. The library pulls to `address(this)`, i.e. this harness.
contract ZapIntakeHarness {
    function pullExact(address token, address from, uint256 amount) external returns (uint256 received) {
        received = ZapIntake.pullExact(IERC20(token), from, amount);
    }

    function pullMeasured(address token, address from, uint256 amount) external returns (uint256 received) {
        received = ZapIntake.pullMeasured(IERC20(token), from, amount);
    }

    function refundLeftoverAbove(address token, uint256 baseline, address to) external {
        ZapIntake.refundLeftoverAbove(IERC20(token), baseline, to);
    }

    function tryPermit(
        address token,
        address owner,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        ZapIntake.tryPermit(IERC20Permit(token), owner, amount, deadline, v, r, s);
    }

    /// @notice The production sequence permit-then-pull: `tryPermit` must swallow a consumed/invalid
    ///         permit and leave the following `transferFrom` to enforce the allowance.
    function tryPermitThenPull(
        address token,
        address owner,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 received) {
        ZapIntake.tryPermit(IERC20Permit(token), owner, amount, deadline, v, r, s);
        received = ZapIntake.pullExact(IERC20(token), owner, amount);
    }
}

/// @notice Non-standard ERC20 whose `transferFrom` delivers `amount + deliveryDelta` to the recipient
///         (negative delta models a fee-on-transfer token, positive delta an over-delivering one).
///         Deliberately minimal: no supply tracking, no extra validation beyond the allowance check,
///         so the guard under test is the one inside `ZapIntake`, not one inside the mock.
contract MockDeviantERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    int256 public deliveryDelta;

    function setDeliveryDelta(int256 delta) external {
        deliveryDelta = delta;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal returns (bool) {
        int256 deliveredSigned = int256(amount) + deliveryDelta;
        uint256 delivered = deliveredSigned > 0 ? uint256(deliveredSigned) : 0;
        balanceOf[from] -= amount;
        balanceOf[to] += delivered;
        return true;
    }
}

/// @notice Plain OZ ERC20 with real ERC-2612 permit, so `tryPermit` is exercised against genuine
///         signature/nonce validation rather than a stub.
contract MockPermitERC20 is ERC20, ERC20Permit {
    constructor() ERC20("Permit Token", "PMT") ERC20Permit("Permit Token") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Offline unit tests (no fork) for the `ZapIntake` intake/refund/permit primitives shared by
///         all zaps. Covers the guards that are unreachable through the zaps' public API on a mainnet
///         fork because the production tokens (USDC, wstETH, fxSAVE) are well-behaved.
contract ZapIntakeV1Test is Test {
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    ZapIntakeHarness harness;
    address user;

    function setUp() public {
        harness = new ZapIntakeHarness();
        user = makeAddr("user");
    }

    // ============ pullExact ============

    function test_PullExact_DeliversExactAmount() public {
        // A standard token pull moves exactly `amount` and reports it back.
        address token = address(new MockERC20("Token", "TKN", 18));
        MockERC20(token).mint(user, 10e18);

        vm.startPrank(user);
        IERC20(token).approve(address(harness), 10e18);
        vm.stopPrank();

        uint256 received = harness.pullExact(token, user, 10e18);

        assertEq(received, 10e18, "reported amount");
        assertEq(IERC20(token).balanceOf(address(harness)), 10e18, "harness credited");
        assertEq(IERC20(token).balanceOf(user), 0, "user debited");
    }

    function test_PullExact_RevertsOnFeeOnTransfer() public {
        // A fee-on-transfer token delivers less than requested; pullExact must fail closed.
        MockDeviantERC20 token = new MockDeviantERC20();
        token.mint(user, 10e18);
        token.setDeliveryDelta(-1);

        vm.startPrank(user);
        token.approve(address(harness), 10e18);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IZapErrors.UnexpectedAmountIn.selector, 10e18, 10e18 - 1));
        harness.pullExact(address(token), user, 10e18);
    }

    function test_PullExact_RevertsOnOverDelivery() public {
        // A token delivering more than requested is just as non-standard; pullExact rejects it too.
        MockDeviantERC20 token = new MockDeviantERC20();
        token.mint(user, 10e18);
        token.setDeliveryDelta(1);

        vm.startPrank(user);
        token.approve(address(harness), 10e18);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IZapErrors.UnexpectedAmountIn.selector, 10e18, 10e18 + 1));
        harness.pullExact(address(token), user, 10e18);
    }

    // ============ pullMeasured ============

    function test_PullMeasured_ToleratesRoundingShortfall() public {
        // Share-based tokens (stETH) may deliver 1-2 wei less; pullMeasured accepts and reports the
        // measured delivery instead of reverting.
        MockDeviantERC20 token = new MockDeviantERC20();
        token.mint(user, 10e18);
        token.setDeliveryDelta(-2);

        vm.startPrank(user);
        token.approve(address(harness), 10e18);
        vm.stopPrank();

        uint256 received = harness.pullMeasured(address(token), user, 10e18);

        assertEq(received, 10e18 - 2, "measured delivery reported");
        assertEq(token.balanceOf(address(harness)), 10e18 - 2, "harness credited measured amount");
    }

    function test_PullMeasured_RevertsOnZeroDelivery() public {
        // A 100% fee (zero delivery) is a hard failure even on the tolerant path.
        MockDeviantERC20 token = new MockDeviantERC20();
        token.mint(user, 10e18);
        token.setDeliveryDelta(-2);

        vm.startPrank(user);
        token.approve(address(harness), 2);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IZapErrors.UnexpectedAmountIn.selector, 2, 0));
        harness.pullMeasured(address(token), user, 2);
    }

    function test_PullMeasured_RevertsOnOverDelivery() public {
        // Over-delivery is rejected on the tolerant path as well: only a shortfall is a rounding
        // artifact, a surplus is a broken token.
        MockDeviantERC20 token = new MockDeviantERC20();
        token.mint(user, 10e18);
        token.setDeliveryDelta(3);

        vm.startPrank(user);
        token.approve(address(harness), 10e18);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IZapErrors.UnexpectedAmountIn.selector, 10e18, 10e18 + 3));
        harness.pullMeasured(address(token), user, 10e18);
    }

    // ============ refundLeftoverAbove ============

    function test_RefundLeftoverAbove_RefundsExcess() public {
        // Any balance above the recorded baseline is unspent input and goes back to the user.
        address token = address(new MockERC20("Token", "TKN", 18));
        MockERC20(token).mint(address(harness), 7e18);

        harness.refundLeftoverAbove(token, 2e18, user);

        assertEq(IERC20(token).balanceOf(user), 5e18, "excess above baseline refunded");
        assertEq(IERC20(token).balanceOf(address(harness)), 2e18, "baseline retained");
    }

    function test_RefundLeftoverAbove_NoopAtOrBelowBaseline() public {
        // With nothing above the baseline there is nothing to refund and no transfer happens.
        address token = address(new MockERC20("Token", "TKN", 18));
        MockERC20(token).mint(address(harness), 2e18);

        harness.refundLeftoverAbove(token, 2e18, user);

        assertEq(IERC20(token).balanceOf(user), 0, "nothing refunded at baseline");
        assertEq(IERC20(token).balanceOf(address(harness)), 2e18, "harness balance untouched");
    }

    // ============ tryPermit ============

    function _signPermit(
        MockPermitERC20 token,
        uint256 ownerPk,
        address spender,
        uint256 amount,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        address owner = vm.addr(ownerPk);
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner, spender, amount, token.nonces(owner), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(ownerPk, digest);
    }

    function test_TryPermit_ValidSignatureSetsAllowance() public {
        // The happy path: a valid ERC-2612 signature grants the harness the allowance.
        uint256 ownerPk = 0xA11CE;
        address owner = vm.addr(ownerPk);
        MockPermitERC20 token = new MockPermitERC20();
        token.mint(owner, 10e18);
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(token, ownerPk, address(harness), 10e18, deadline);
        harness.tryPermit(address(token), owner, 10e18, deadline, v, r, s);

        assertEq(token.allowance(owner, address(harness)), 10e18, "allowance granted by permit");
    }

    function test_TryPermit_FrontRunConsumedNonce_ZapStillSucceeds() public {
        // The griefing scenario tryPermit exists for: an attacker lifts the signature from the mempool
        // and submits token.permit first, consuming the nonce. The zap's own permit call then reverts,
        // but tryPermit swallows it and the pull succeeds on the allowance the front-run itself granted.
        uint256 ownerPk = 0xA11CE;
        address owner = vm.addr(ownerPk);
        MockPermitERC20 token = new MockPermitERC20();
        token.mint(owner, 10e18);
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(token, ownerPk, address(harness), 10e18, deadline);

        // Attacker front-runs with the same public signature.
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        IERC20Permit(address(token)).permit(owner, address(harness), 10e18, deadline, v, r, s);
        vm.stopPrank();

        uint256 received = harness.tryPermitThenPull(address(token), owner, 10e18, deadline, v, r, s);

        assertEq(received, 10e18, "zap proceeds despite consumed permit");
        assertEq(token.balanceOf(address(harness)), 10e18, "funds pulled");
    }

    function test_TryPermit_InvalidSignature_PullRevertsOnAllowance() public {
        // With a garbage signature and no allowance, tryPermit swallows the permit failure and the
        // subsequent transferFrom reverts with the token's own allowance error - funds never move.
        uint256 ownerPk = 0xA11CE;
        address owner = vm.addr(ownerPk);
        MockPermitERC20 token = new MockPermitERC20();
        token.mint(owner, 10e18);
        uint256 deadline = block.timestamp + 1 hours;

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(harness), 0, 10e18)
        );
        harness.tryPermitThenPull(address(token), owner, 10e18, deadline, 27, bytes32(uint256(1)), bytes32(uint256(2)));
    }
}
