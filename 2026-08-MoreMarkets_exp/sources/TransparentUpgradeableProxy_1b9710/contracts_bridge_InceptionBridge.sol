// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.20;
// pragma abicoder v2;

// import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

// import "@openzeppelin/contracts/interfaces/IERC20.sol";
// import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
// import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// import "./InceptionBridgeStorage.sol";

// import "../interfaces/IInceptionBridge.sol";
// import "../interfaces/IXERC20Lockbox.sol";

// import "../lib/EthereumVerifier.sol";
// import "../lib/ProofParser.sol";
// import "../lib/Utils.sol";

// /// @author The InceptionLRT team
// /// @title The InceptionBridge contract
// /// @notice Facilitates cross-chain token(asset) transfers using the burn-mint pattern.
// contract InceptionBridge is
//     OwnableUpgradeable,
//     PausableUpgradeable,
//     ReentrancyGuardUpgradeable,
//     InceptionBridgeStorage,
//     IInceptionBridge
// {
//     using SafeERC20 for IERC20;

//     /// @custom:oz-upgrades-unsafe-allow constructor
//     /// @dev payable modifier reduces the deployment cost
//     constructor() payable {
//         _disableInitializers();
//     }

//     function initialize(
//         address initialOwner,
//         address notary
//     ) external initializer {
//         __Ownable_init(initialOwner);
//         __Pausable_init();
//         __ReentrancyGuard_init();

//         __initInceptionBridgeStorage(notary);
//     }

//     /*//////////////////////////////
//     ////// Deposit functions //////
//     ////////////////////////////*/

//     /**
//      * @dev Tokens on source and destination chains are linked with independent supplies.
//      * Burns tokens on source chain (to later mint it on the destination chain).
//      * @param fromToken is one of the many supported tokens on the current chain.
//      * @param destinationChain is the destination chain ID.
//      * @param receiver of `amount` on the destination chain.
//      * @param amount of tokens to be transferred
//      */
//     function deposit(
//         address fromToken,
//         uint256 destinationChain,
//         address receiver,
//         uint256 amount
//     ) external override nonReentrant whenNotPaused {
//         _beforeDeposit();
//         _updateDepositCaps(fromToken, amount);

//         if (getDestination(fromToken, destinationChain) != address(0)) {
//             _deposit(fromToken, destinationChain, receiver, amount);
//         } else revert UnknownDestinationChain();
//     }

//     function _deposit(
//         address fromToken,
//         uint256 destinationChain,
//         address receiver,
//         uint256 amount
//     ) internal {
//         if (_bridgeAddressByChainId[destinationChain] == address(0)) {
//             revert UnknownDestinationChain();
//         }
//         address sender = msg.sender;

//         address lockbox = xerc20TokenRegistry[fromToken];
//         if (lockbox == address(0)) {
//             _safeBurn(fromToken, sender, amount);
//         } else {
//             _depositIntoLockbox(lockbox, fromToken, sender, amount);
//         }

//         Metadata memory metaData = Metadata(
//             Utils.stringToBytes32(IERC20Extra(fromToken).name()),
//             Utils.stringToBytes32(IERC20Extra(fromToken).symbol()),
//             0,
//             address(0)
//         );

//         unchecked {
//             ++_globalNonce;
//         }

//         emit Deposited(
//             destinationChain,
//             _bridgeAddressByChainId[destinationChain],
//             sender,
//             receiver,
//             fromToken,
//             getDestination(fromToken, destinationChain),
//             amount,
//             _globalNonce,
//             metaData
//         );
//     }

//     function _depositIntoLockbox(
//         address lockbox,
//         address fromToken,
//         address sender,
//         uint256 amount
//     ) internal {
//         address xerc20 = address(IXERC20Lockbox(lockbox).XERC20());
//         if (xerc20 == address(0)) revert XERC20ZeroAddress();

//         /// deposit into the lockBox
//         IERC20(fromToken).safeTransferFrom(sender, address(this), amount);
//         IERC20(fromToken).safeApprove(lockbox, amount);
//         IXERC20Lockbox(lockbox).deposit(amount);

//         _safeBurn(xerc20, address(this), amount);
//     }

//     /*/////////////////////////////////
//     ////// Withdrawal functions //////
//     ///////////////////////////////*/

//     /// @dev Serves the authorized (signed) withdrawal request by the bridge committee.
//     /// @dev Mints the corresponding token to the `Deposited.receiver` address.
//     /// `encodedProof` represents the RLP-encoded 'Deposited' receipt.
//     /// @param rawReceipt is the raw deposit transaction receipt.
//     /// @param proofSignature is the signature of keccak256(`encodedProof`) by the operator.
//     function withdraw(
//         /* encodedProof */ bytes calldata,
//         bytes calldata rawReceipt,
//         bytes memory proofSignature
//     ) external override nonReentrant whenNotPaused {
//         uint256 proofOffset;
//         uint256 receiptOffset;
//         assembly {
//             proofOffset := add(0x4, calldataload(4))
//             receiptOffset := add(0x4, calldataload(36))
//         }

//         (
//             EthereumVerifier.State memory state,
//             EthereumVerifier.DepositType depositType
//         ) = EthereumVerifier.parseTransactionReceipt(receiptOffset);

//         if (state.chainId != block.chainid)
//             revert ReceiptWrongChain(block.chainid, state.chainId);

//         ProofParser.Proof memory proof = ProofParser.parseProof(proofOffset);

//         if (state.contractAddress == address(0))
//             revert InvalidContractAddress();

//         if (state.destinationContract != address(this))
//             revert WrongDestinationBridge();

//         if (_bridgeAddressByChainId[proof.chainId] != state.contractAddress)
//             revert UnknownBridge();

//         state.receiptHash = keccak256(rawReceipt);
//         proof.status = 0x01;
//         proof.receiptHash = state.receiptHash;
//         bytes32 proofHash;
//         assembly {
//             proofHash := keccak256(proof, _PROOF_LENGTH)
//         }

//         if (ECDSA.recover(proofHash, proofSignature) != notary)
//             revert WrongSignature();

//         _withdraw(state, depositType, proof, proofHash);
//     }

//     function _withdraw(
//         EthereumVerifier.State memory state,
//         EthereumVerifier.DepositType depositType,
//         ProofParser.Proof memory proof,
//         bytes32 payload
//     ) internal {
//         if (_usedProofs[payload]) {
//             revert WithdrawalProofUsed();
//         }
//         _usedProofs[payload] = true;
//         if (depositType == EthereumVerifier.DepositType.TokenDeposit) {
//             _withdraw(state, proof);
//         } else revert InvalidAssetType();
//     }

//     function _withdraw(
//         EthereumVerifier.State memory state,
//         ProofParser.Proof memory proof
//     ) internal {
//         if (state.fromToken == address(0)) revert InvalidFromTokenAddress();
//         if (getDestination(state.toToken, proof.chainId) != state.fromToken)
//             revert UnknownDestination();

//         _updateWithdrawCaps(state.toToken, state.amount);
//         address lockbox = xerc20TokenRegistry[state.toToken];
//         if (lockbox == address(0)) {
//             _safeMint(state.toToken, state.receiver, state.amount);
//         } else {
//             address xerc20 = address(IXERC20Lockbox(lockbox).XERC20());
//             if (xerc20 == address(0)) revert XERC20ZeroAddress();

//             _safeMint(xerc20, address(this), state.amount);
//             IXERC20Lockbox(lockbox).withdrawTo(state.receiver, state.amount);
//         }

//         emit Withdrawn(
//             state.receiptHash,
//             state.sender,
//             state.receiver,
//             state.fromToken,
//             state.toToken,
//             state.amount
//         );
//     }

//     function getDestination(
//         address fromToken,
//         uint256 destinationChain
//     ) public view returns (address) {
//         return
//             _destinationTokens[
//                 keccak256(
//                     abi.encodePacked(
//                         fromToken,
//                         block.chainid,
//                         _bridgeAddressByChainId[destinationChain],
//                         destinationChain
//                     )
//                 )
//             ];
//     }

//     /*//////////////////////////
//     ////// SET functions //////
//     ////////////////////////*/

//     function setNotary(address notaryAddress) external onlyOwner {
//         _setNotary(notaryAddress);
//     }

//     function setShortCap(
//         address tokenAddress,
//         uint256 amount
//     ) external onlyOwner {
//         _setShortCap(tokenAddress, amount);
//     }

//     function setShortCapDuration(uint256 duration) external onlyOwner {
//         _setShortCapDuration(duration);
//     }

//     function setLongCapDuration(uint256 duration) external onlyOwner {
//         _setLongCapDuration(duration);
//     }

//     function setLongCap(address token, uint256 amount) external onlyOwner {
//         _setLongCap(token, amount);
//     }

//     function addBridge(
//         address bridge,
//         uint256 destinationChain
//     ) external onlyOwner {
//         _addBridge(bridge, destinationChain);
//     }

//     function removeBridge(uint256 destinationChain) external onlyOwner {
//         _removeBridge(destinationChain);
//     }

//     function addDestination(
//         address fromToken,
//         uint256 destinationChain,
//         address toToken
//     ) external onlyOwner {
//         _addDestination(fromToken, destinationChain, toToken);
//     }

//     function removeDestination(
//         address fromToken,
//         uint256 destinationChain,
//         address toToken
//     ) external onlyOwner {
//         _removeDestination(fromToken, destinationChain, toToken);
//     }

//     function setXERC20Lockbox(
//         address token,
//         address xerc20Lockbox
//     ) external onlyOwner {
//         _setXERC20Lockbox(token, xerc20Lockbox);
//     }

//     /*///////////////////////////////
//     ////// Pausable functions //////
//     /////////////////////////////*/

//     function pause() external onlyOwner {
//         _pause();
//     }

//     function unpause() external onlyOwner {
//         _unpause();
//     }

//     /*///////////////////////////////
//     //////// Safe functions ////////
//     /////////////////////////////*/

//     function _safeBurn(
//         address token,
//         address account,
//         uint256 amount
//     ) internal {
//         uint256 balanceBefore = IERC20(token).balanceOf(account);
//         IERC20Mintable(token).burn(account, amount);
//         uint256 balanceAfter = IERC20(token).balanceOf(account);
//         if (balanceAfter + amount != balanceBefore) {
//             revert BurnFailed();
//         }
//     }

//     function _safeMint(
//         address token,
//         address account,
//         uint256 amount
//     ) internal {
//         uint256 balanceBefore = IERC20(token).balanceOf(account);
//         IERC20Mintable(token).mint(account, amount);
//         uint256 balanceAfter = IERC20(token).balanceOf(account);
//         if (balanceBefore + amount != balanceAfter) {
//             revert MintFailed();
//         }
//     }
// }
