// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// creates arrays of uint, int and address

contract Array {
    function ua() internal pure returns (uint256[] memory result) {
        result = new uint256[](0);
    }

    function ua(uint256 a_) internal pure returns (uint256[] memory result) {
        result = new uint256[](1);
        result[0] = a_;
    }

    function ua(uint256 a_, uint256 b) internal pure returns (uint256[] memory result) {
        result = new uint256[](2);
        result[0] = a_;
        result[1] = b;
    }

    function ua(uint256 a_, uint256 b, uint256 c) internal pure returns (uint256[] memory result) {
        result = new uint256[](3);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
    }

    function ua(uint256 a_, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory result) {
        result = new uint256[](4);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
    }

    function ua(
        uint256 a_,
        uint256 b,
        uint256 c,
        uint256 d,
        uint256 e
    ) internal pure returns (uint256[] memory result) {
        result = new uint256[](5);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
    }

    function ua(
        uint256 a_,
        uint256 b,
        uint256 c,
        uint256 d,
        uint256 e,
        uint256 f
    ) internal pure returns (uint256[] memory result) {
        result = new uint256[](6);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
    }

    function ua(
        uint256 a_,
        uint256 b,
        uint256 c,
        uint256 d,
        uint256 e,
        uint256 f,
        uint256 g
    ) internal pure returns (uint256[] memory result) {
        result = new uint256[](7);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
    }

    function ua(
        uint256 a_,
        uint256 b,
        uint256 c,
        uint256 d,
        uint256 e,
        uint256 f,
        uint256 g,
        uint256 h
    ) internal pure returns (uint256[] memory result) {
        result = new uint256[](8);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
    }

    function ua(
        uint256 a_,
        uint256 b,
        uint256 c,
        uint256 d,
        uint256 e,
        uint256 f,
        uint256 g,
        uint256 h,
        uint256 i
    ) internal pure returns (uint256[] memory result) {
        result = new uint256[](9);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
    }

    function ua(
        uint256 a_,
        uint256 b,
        uint256 c,
        uint256 d,
        uint256 e,
        uint256 f,
        uint256 g,
        uint256 h,
        uint256 i,
        uint256 j
    ) internal pure returns (uint256[] memory result) {
        result = new uint256[](10);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
        result[9] = j;
    }

    function ua(
        uint256 a_,
        uint256 b,
        uint256 c,
        uint256 d,
        uint256 e,
        uint256 f,
        uint256 g,
        uint256 h,
        uint256 i,
        uint256 j,
        uint256 k
    ) internal pure returns (uint256[] memory result) {
        result = new uint256[](11);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
        result[9] = j;
        result[10] = k;
    }

    function ua(
        uint256 a_,
        uint256 b,
        uint256 c,
        uint256 d,
        uint256 e,
        uint256 f,
        uint256 g,
        uint256 h,
        uint256 i,
        uint256 j,
        uint256 k,
        uint256 l
    ) internal pure returns (uint256[] memory result) {
        result = new uint256[](12);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
        result[9] = j;
        result[10] = k;
        result[11] = l;
    }

    function ua(
        uint256 a_,
        uint256 b,
        uint256 c,
        uint256 d,
        uint256 e,
        uint256 f,
        uint256 g,
        uint256 h,
        uint256 i,
        uint256 j,
        uint256 k,
        uint256 l,
        uint256 m
    ) internal pure returns (uint256[] memory result) {
        result = new uint256[](13);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
        result[9] = j;
        result[10] = k;
        result[11] = l;
        result[12] = m;
    }

    function ia() internal pure returns (int256[] memory result) {
        result = new int256[](0);
    }

    function ia(int256 a_) internal pure returns (int256[] memory result) {
        result = new int256[](1);
        result[0] = a_;
    }

    function ia(int256 a_, int256 b) internal pure returns (int256[] memory result) {
        result = new int256[](2);
        result[0] = a_;
        result[1] = b;
    }

    function ia(int256 a_, int256 b, int256 c) internal pure returns (int256[] memory result) {
        result = new int256[](3);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
    }

    function ia(int256 a_, int256 b, int256 c, int256 d) internal pure returns (int256[] memory result) {
        result = new int256[](4);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
    }

    function ia(int256 a_, int256 b, int256 c, int256 d, int256 e) internal pure returns (int256[] memory result) {
        result = new int256[](5);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
    }

    function ia(
        int256 a_,
        int256 b,
        int256 c,
        int256 d,
        int256 e,
        int256 f
    ) internal pure returns (int256[] memory result) {
        result = new int256[](6);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
    }

    function ia(
        int256 a_,
        int256 b,
        int256 c,
        int256 d,
        int256 e,
        int256 f,
        int256 g
    ) internal pure returns (int256[] memory result) {
        result = new int256[](7);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
    }

    function ia(
        int256 a_,
        int256 b,
        int256 c,
        int256 d,
        int256 e,
        int256 f,
        int256 g,
        int256 h
    ) internal pure returns (int256[] memory result) {
        result = new int256[](8);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
    }

    function ia(
        int256 a_,
        int256 b,
        int256 c,
        int256 d,
        int256 e,
        int256 f,
        int256 g,
        int256 h,
        int256 i
    ) internal pure returns (int256[] memory result) {
        result = new int256[](9);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
    }

    function ia(
        int256 a_,
        int256 b,
        int256 c,
        int256 d,
        int256 e,
        int256 f,
        int256 g,
        int256 h,
        int256 i,
        int256 j
    ) internal pure returns (int256[] memory result) {
        result = new int256[](10);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
        result[9] = j;
    }

    function aa() internal pure returns (address[] memory result) {
        result = new address[](0);
    }

    function aa(address a_) internal pure returns (address[] memory result) {
        result = new address[](1);
        result[0] = a_;
    }

    function aa(address a_, address b) internal pure returns (address[] memory result) {
        result = new address[](2);
        result[0] = a_;
        result[1] = b;
    }

    function aa(address a_, address b, address c) internal pure returns (address[] memory result) {
        result = new address[](3);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
    }

    function aa(address a_, address b, address c, address d) internal pure returns (address[] memory result) {
        result = new address[](4);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
    }

    function aa(
        address a_,
        address b,
        address c,
        address d,
        address e
    ) internal pure returns (address[] memory result) {
        result = new address[](5);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
    }

    function aa(
        address a_,
        address b,
        address c,
        address d,
        address e,
        address f
    ) internal pure returns (address[] memory result) {
        result = new address[](6);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
    }

    function sa() internal pure returns (string[] memory result) {
        result = new string[](0);
    }

    function sa(string memory a_) internal pure returns (string[] memory result) {
        result = new string[](1);
        result[0] = a_;
    }

    function sa(string memory a_, string memory b) internal pure returns (string[] memory result) {
        result = new string[](2);
        result[0] = a_;
        result[1] = b;
    }

    function sa(string memory a_, string memory b, string memory c) internal pure returns (string[] memory result) {
        result = new string[](3);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d
    ) internal pure returns (string[] memory result) {
        result = new string[](4);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d,
        string memory e
    ) internal pure returns (string[] memory result) {
        result = new string[](5);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d,
        string memory e,
        string memory f
    ) internal pure returns (string[] memory result) {
        result = new string[](6);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d,
        string memory e,
        string memory f,
        string memory g
    ) internal pure returns (string[] memory result) {
        result = new string[](7);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d,
        string memory e,
        string memory f,
        string memory g,
        string memory h
    ) internal pure returns (string[] memory result) {
        result = new string[](8);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d,
        string memory e,
        string memory f,
        string memory g,
        string memory h,
        string memory i
    ) internal pure returns (string[] memory result) {
        result = new string[](9);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d,
        string memory e,
        string memory f,
        string memory g,
        string memory h,
        string memory i,
        string memory j
    ) internal pure returns (string[] memory result) {
        result = new string[](10);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
        result[9] = j;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d,
        string memory e,
        string memory f,
        string memory g,
        string memory h,
        string memory i,
        string memory j,
        string memory k
    ) internal pure returns (string[] memory result) {
        result = new string[](11);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
        result[9] = j;
        result[10] = k;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d,
        string memory e,
        string memory f,
        string memory g,
        string memory h,
        string memory i,
        string memory j,
        string memory k,
        string memory l
    ) internal pure returns (string[] memory result) {
        result = new string[](12);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
        result[9] = j;
        result[10] = k;
        result[11] = l;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d,
        string memory e,
        string memory f,
        string memory g,
        string memory h,
        string memory i,
        string memory j,
        string memory k,
        string memory l,
        string memory m
    ) internal pure returns (string[] memory result) {
        result = new string[](13);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
        result[9] = j;
        result[10] = k;
        result[11] = l;
        result[12] = m;
    }

    function cons(uint256 car, uint256[] memory cdr) private pure returns (uint256[] memory list) {
        list = new uint256[](cdr.length + 1);
        list[0] = car;
        for (uint256 i = 0; i < cdr.length; i++) {
            list[i + 1] = cdr[i];
        }
    }

    function cons(int256 car, int256[] memory cdr) private pure returns (int256[] memory list) {
        list = new int256[](cdr.length + 1);
        list[0] = car;
        for (uint256 i = 0; i < cdr.length; i++) {
            list[i + 1] = cdr[i];
        }
    }

    function cons(address car, address[] memory cdr) private pure returns (address[] memory list) {
        list = new address[](cdr.length + 1);
        list[0] = car;
        for (uint256 i = 0; i < cdr.length; i++) {
            list[i + 1] = cdr[i];
        }
    }

    function ultimate(uint256[] memory list) internal pure returns (uint256) {
        return list[list.length - 1];
    }

    function ultimate(int256[] memory list) internal pure returns (int256) {
        return list[list.length - 1];
    }

    function ultimate(address[] memory list) internal pure returns (address) {
        return list[list.length - 1];
    }

    function penultimate(uint256[] memory list) internal pure returns (uint256) {
        return list[list.length - 2];
    }

    function penultimate(int256[] memory list) internal pure returns (int256) {
        return list[list.length - 2];
    }

    function penultimate(address[] memory list) internal pure returns (address) {
        return list[list.length - 2];
    }

    function initial(uint256[] memory list) internal pure returns (uint256) {
        return list[0];
    }

    function initial(int256[] memory list) internal pure returns (int256) {
        return list[0];
    }

    function initial(address[] memory list) internal pure returns (address) {
        return list[0];
    }

    function second(uint256[] memory list) internal pure returns (uint256) {
        return list[1];
    }

    function second(int256[] memory list) internal pure returns (int256) {
        return list[1];
    }

    function second(address[] memory list) internal pure returns (address) {
        return list[1];
    }
}
