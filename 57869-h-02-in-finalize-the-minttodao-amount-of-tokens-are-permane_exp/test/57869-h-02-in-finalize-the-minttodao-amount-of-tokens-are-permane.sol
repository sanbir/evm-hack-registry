// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Daos.live DaosLive — finalize mints _mintToDao into the contract
    (Shieldify, DaosLive, finding 57869 / H-02).
    SYNTHETIC, cheatcode-free. The blamed mint is copied verbatim (@> VULN).

    finalize mints _mintToDao tokens to address(this). DaosLive has no
    withdraw, sweep, or transfer. The DAO manager's balance stays 0 and
    balanceOf(this) stays at the minted amount.

    The control mints the same amount straight to the DAO manager. */

interface IDaosToken {
    function mint(address to, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

contract DaosToken is IDaosToken {
    string public name = "DaosLive";
    string public symbol = "DAO";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract DaosLive {
    address public owner;
    address public token;
    address public daoManager;
    string public finalizedName;
    uint256 public snipeAmount;

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    constructor(address _token, address _manager) {
        owner = msg.sender;
        token = _token;
        daoManager = _manager;
    }

    function finalize(
        string calldata name_,
        string calldata symbol_,
        uint256 _mintToDao,
        uint256 _snipeAmount
    ) external onlyOwner {
        finalizedName = name_;
        snipeAmount = _snipeAmount;
        symbol_;

        uint256 mintToDao = _mintToDao;
        if (mintToDao > 0) {
            // @> VULN: minted to this contract. There is no withdraw, so the DAO manager can never move these tokens.
            IDaosToken(token).mint(address(this), mintToDao);
        }
    }
}

contract Exploit {
    uint256 public constant MINT_TO_DAO = 1000e18;
    address public constant MANAGER = 0x000000000000000000000000000000000000bEEF;

    DaosToken public token; // nonce 1
    DaosLive public dao; // nonce 2

    uint256 public stuck;
    uint256 public managerBalance;
    bool public withdrawMissing;

    constructor() {
        token = new DaosToken();
        dao = new DaosLive(address(token), MANAGER);
    }

    function run() external {
        require(token.balanceOf(address(dao)) == 0, "already funded");
        require(token.balanceOf(MANAGER) == 0, "manager already funded");

        dao.finalize("Live", "DAO", MINT_TO_DAO, 0);

        stuck = token.balanceOf(address(dao));
        managerBalance = token.balanceOf(MANAGER);
        require(stuck == MINT_TO_DAO, "mint missed the contract");
        require(managerBalance == 0, "manager received tokens");
        require(bytes(dao.finalizedName()).length == 4, "finalize did not run");

        (bool swept,) = address(dao).call(abi.encodeWithSignature("withdraw(address)", address(token)));
        withdrawMissing = !swept;
        require(withdrawMissing, "withdraw exists");
        require(token.balanceOf(address(dao)) == MINT_TO_DAO, "tokens left the contract");
        require(token.balanceOf(MANAGER) == 0, "manager was paid by a sweep");
    }
}
