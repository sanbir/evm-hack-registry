// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Blueberry VaultEscrow — deposit sends USDC to the legacy Hyperliquid
    spot bridge (Pashov, finding #61456 / H-03, 12 March 2025).

    SYNTHETIC, cheatcode-free. deposit transfers N = 1000 USDC (6 decimals)
    to 0x2222...2222. The current HyperCore route for token index 200 is
    0x2000...00c8. The fixed deposit sends N there. A local balance on each
    address is the other side of the bridge. */

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract VaultEscrow {
    /// @notice The address of the hyperliquid spot bridge, used for sending tokens to L1.
    address public constant HYPERLIQUID_SPOT_BRIDGE = 0x2222222222222222222222222222222222222222;

    Token public token;

    constructor(Token token_) {
        token = token_;
    }

    function deposit(uint64 amount) external {
        // @> VULN: legacy bridge, not the token-index system address 0x2000...00c8
        token.transfer(HYPERLIQUID_SPOT_BRIDGE, amount);
    }
}

contract VaultEscrowFixed {
    Token public token;
    uint64 public constant TOKEN_INDEX = 200;

    constructor(Token token_) {
        token = token_;
    }

    function systemAddress(uint64 tokenIndex) public pure returns (address) {
        return address(uint160((uint256(0x20) << 152) | uint256(tokenIndex)));
    }

    function deposit(uint64 amount) external {
        token.transfer(systemAddress(TOKEN_INDEX), amount);
    }
}

contract Exploit {
    uint64 public constant N = 1_000_000_000;
    address public constant LEGACY = 0x2222222222222222222222222222222222222222;
    address public constant CORE = 0x20000000000000000000000000000000000000C8;

    Token public token;
    VaultEscrow public escrow;

    constructor() {
        token = new Token("USD Coin", "USDC", 6);
        escrow = new VaultEscrow(token);
    }

    function run() external {
        token.mint(address(escrow), N);
        escrow.deposit(N);
        require(token.balanceOf(LEGACY) == N, "legacy did not receive N");
        require(token.balanceOf(CORE) == 0, "core received tokens");
        require(token.balanceOf(address(escrow)) == 0, "escrow still holds N");
        require(CORE != LEGACY, "addresses match");
    }
}
