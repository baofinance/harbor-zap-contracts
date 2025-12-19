// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GenesisETHZapV3} from "src/minter/GenesisETHZap_v3.sol";

/// @notice Interface for stETH submit function
interface ISTETHV2 {
    function submit(address referral) external payable returns (uint256);
    function getSharesByPooledEth(uint256 _ethAmount) external view returns (uint256);
}

/// @notice Interface for wstETH
interface IWstETHV2 {
    // forge-lint: disable-next-line(mixed-case-function)
    function getWstETHByStETH(uint256 stEthAmount) external view returns (uint256);
}

contract GenesisETHZapForkMainnetTest is Test {
    // Mainnet addresses
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    
    // Deployed zap contract on mainnet
    address constant DEPLOYED_ZAP = 0xc199605A723D21FD597Ac206fE650bE4191333De;
    
    GenesisETHZapV3 zap;
    address user1;
    address receiver;

    function setUp() public {
        // Fork mainnet from latest block
        // Note: vm.createSelectFork without block number forks from latest
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        
        // Use deployed contract - verify it has code first
        uint256 zapCodeSize;
        assembly {
            zapCodeSize := extcodesize(DEPLOYED_ZAP)
        }
        require(zapCodeSize > 0, "Zap contract has no code");
        
        zap = GenesisETHZapV3(payable(DEPLOYED_ZAP));
        
        // Read Genesis address from deployed zap contract
        address genesisFromZap = zap.GENESIS();
        console.log("=== Fork Test Setup ===");
        console.log("Zap Contract:", DEPLOYED_ZAP);
        console.log("Zap Code Size:", zapCodeSize);
        console.log("Genesis address from zap:", genesisFromZap);
        console.log("Fork Block:", block.number);
        
        // Verify Genesis contract has code (it's a proxy, so should have proxy code)
        uint256 genesisCodeSize;
        assembly {
            genesisCodeSize := extcodesize(genesisFromZap)
        }
        console.log("Genesis contract code size:", genesisCodeSize);
        
        // For transparent proxies, they should have code (the proxy implementation)
        // But if it's been upgraded/removed, codeSize might be 0
        // We'll still try the test to see what happens
        
        user1 = makeAddr("user1");
        receiver = makeAddr("receiver");
        
        vm.deal(user1, 100 ether);
    }

    /// @notice Helper to calculate expected wstETH from ETH amount (for slippage protection)
    function _calculateMinWstEthFromEth(uint256 ethAmount) internal view returns (uint256) {
        uint256 stEthShares = ISTETHV2(STETH).getSharesByPooledEth(ethAmount);
        uint256 wstEthAmount = IWstETHV2(WSTETH).getWstETHByStETH(stEthShares);
        return wstEthAmount * 99 / 100; // 1% slippage buffer
    }

    function test_ZapEth_WithDeployedContract() public {
        // Get Genesis address from deployed zap contract
        address genesis = zap.GENESIS();
        
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        // Calculate minWstEthOut with 1% slippage buffer
        uint256 minWstEthOut = _calculateMinWstEthFromEth(ethAmount);
        
        console.log("=== Testing Deployed Zap Contract ===");
        console.log("Zap Contract:", DEPLOYED_ZAP);
        console.log("Genesis Contract:", genesis);
        console.log("ETH Amount:", ethAmount);
        console.log("Min wstETH Out:", minWstEthOut);
        console.log("Receiver:", receiver);
        console.log("");
        
        uint256 zapWstEthBalBefore = IERC20(WSTETH).balanceOf(DEPLOYED_ZAP);
        uint256 userEthBefore = user1.balance;
        
        console.log("Zap wstETH Before:", zapWstEthBalBefore);
        console.log("User ETH Before:", userEthBefore);
        console.log("");
        
        // Execute zapEth - this will either succeed or revert with an error
        // If Genesis doesn't exist on fork, it will revert in _depositToGenesis
        try zap.zapEth{value: ethAmount}(receiver, minWstEthOut) returns (uint256 sharesOut) {
            vm.stopPrank();
            
            uint256 zapWstEthBalAfter = IERC20(WSTETH).balanceOf(DEPLOYED_ZAP);
            uint256 userEthAfter = user1.balance;
            
            console.log("=== SUCCESS ===");
            console.log("wstETH Received (sharesOut):", sharesOut);
            console.log("Zap wstETH After:", zapWstEthBalAfter);
            // forge-lint: disable-next-line(unsafe-typecast)
            // forge-lint: disable-next-line(unsafe-typecast)
            console.log("Zap wstETH Change:", int256(zapWstEthBalAfter) - int256(zapWstEthBalBefore));
            console.log("User ETH After:", userEthAfter);
            console.log("User ETH Spent:", userEthBefore - userEthAfter);
            
            // Basic assertions
            assertGt(sharesOut, 0, "Should receive wstETH");
            assertEq(userEthAfter, userEthBefore - ethAmount, "User ETH not deducted");
            assertEq(zapWstEthBalAfter, zapWstEthBalBefore, "Zap contract should not hold wstETH after deposit");
            
            // Verify allowances are cleared
            assertEq(IERC20(STETH).allowance(DEPLOYED_ZAP, WSTETH), 0, "stETH allowance not cleared");
            assertEq(IERC20(WSTETH).allowance(DEPLOYED_ZAP, genesis), 0, "wstETH allowance not cleared");
        } catch Error(string memory reason) {
            vm.stopPrank();
            console.log("=== FAILED ===");
            console.log("Error:", reason);
            // Re-throw to fail the test
            revert(reason);
        } catch (bytes memory lowLevelData) {
            vm.stopPrank();
            console.log("=== FAILED (Low-level) ===");
            console.logBytes(lowLevelData);
            // Re-throw to fail the test
            revert("Low-level error");
        }

    }
}

