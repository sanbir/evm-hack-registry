// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IAny2EVMMessageReceiver} from "./IAny2EVMMessageReceiver.sol";
import {Client} from "./Client.sol";
import {IERC165} from "./IERC165.sol";

// Real Chainlink CCIP base contract (smartcontractkit/ccip,
// contracts/src/v0.8/ccip/applications/CCIPReceiver.sol). Vendored unmodified
// except the IERC165 import path is localised. This is the exact base the
// audited `BridgeCCIP is CCIPReceiver, Ownable` inherits from; it enforces
// msg.sender == i_ccipRouter but performs NO source-chain / sender validation
// (that is left to the application, which is the subject of finding 55536).
abstract contract CCIPReceiver is IAny2EVMMessageReceiver, IERC165 {
  address internal immutable i_ccipRouter;

  constructor(address router) {
    if (router == address(0)) revert InvalidRouter(address(0));
    i_ccipRouter = router;
  }

  function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
    return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
  }

  /// @inheritdoc IAny2EVMMessageReceiver
  function ccipReceive(Client.Any2EVMMessage calldata message) external virtual override onlyRouter {
    _ccipReceive(message);
  }

  function _ccipReceive(Client.Any2EVMMessage memory message) internal virtual;

  function getRouter() public view virtual returns (address) {
    return address(i_ccipRouter);
  }

  error InvalidRouter(address router);

  modifier onlyRouter() {
    if (msg.sender != getRouter()) revert InvalidRouter(msg.sender);
    _;
  }
}
