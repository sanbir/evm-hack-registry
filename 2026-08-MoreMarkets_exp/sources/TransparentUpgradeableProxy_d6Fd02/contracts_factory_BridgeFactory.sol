// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.20;

// import "solmate/src/utils/CREATE3.sol";
// import "../XERC20/XERC20.sol";
// import "../XERC20/XERC20Lockbox.sol";
// import "../interfaces/IFactory.sol";

// /// @author The InceptionLRT team
// /// @title The BridgeFactory Contract
// /// @notice Facilitates the deployment of contracts via CREATE2 and CREATE3
// contract BridgeFactory is IFactory {
//     /**
//      *****************************************************************************
//      ****************************** CREATE2 FACTORY ******************************
//      *****************************************************************************
//      */

//     bytes32 public bridgeSalt = "InceptionLRT Factory";

//     function deployCreate2(
//         bytes calldata creationCode
//     ) external returns (address) {
//         return _deployCreate2(creationCode, msg.sender);
//     }

//     function _deployCreate2(
//         bytes memory bytecode,
//         address _sender
//     ) internal returns (address) {
//         address addr = _create2(bytecode, _sender);

//         emit ContractCreated(addr);
//         return addr;
//     }

//     function _create2(
//         bytes memory bytecode,
//         address _sender
//     ) internal returns (address) {
//         address payable addr;
//         bytes32 salt = _getSalt(_sender);

//         assembly {
//             addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
//             if iszero(extcodesize(addr)) {
//                 revert(0, 0)
//             }
//         }

//         return addr;
//     }

//     function getDeploymentCreate2Address(
//         bytes memory bytecode,
//         address _sender
//     ) external view returns (address) {
//         bytes32 salt = _getSalt(_sender);
//         bytes32 rawAddress = keccak256(
//             abi.encodePacked(
//                 bytes1(0xff),
//                 address(this),
//                 salt,
//                 keccak256(bytecode)
//             )
//         );

//         return address(bytes20(rawAddress << 96));
//     }

//     function _getSalt(address _sender) internal view returns (bytes32) {
//         return keccak256(abi.encodePacked(bridgeSalt, _sender));
//     }

//     /**
//      ****************************************************************************
//      ****************************** XERC20 FACTORY ******************************
//      ****************************************************************************
//      */

//     /**
//      * @notice Deploys an XERC20 contract using CREATE3
//      * @dev _limits and _minters must be the same length
//      * @param _name The name of the token
//      * @param _symbol The symbol of the token
//      * @return _xerc20 The address of the xerc20
//      */
//     function deployXERC20(
//         string memory _name,
//         string memory _symbol
//     ) external returns (address _xerc20) {
//         _xerc20 = _deployXERC20(_name, _symbol);

//         emit XERC20Deployed(_xerc20);
//     }

//     /**
//      * @notice Deploys an XERC20Lockbox contract using CREATE3
//      *
//      * @dev When deploying a lockbox for the gas token of the chain, then, the base token needs to be address(0)
//      * @param _xerc20 The address of the xerc20 that you want to deploy a lockbox for
//      * @param _baseToken The address of the base token that you want to lock
//      * @param _isNative Whether or not the base token is the native (gas) token of the chain. Eg: MATIC for polygon chain
//      * @return _lockbox The address of the lockbox
//      */
//     function deployLockbox(
//         address _xerc20,
//         address _baseToken,
//         bool _isNative
//     ) external returns (address _lockbox) {
//         if (
//             (_baseToken == address(0) && !_isNative) ||
//             (_isNative && _baseToken != address(0))
//         ) revert IXERC20Factory_BadTokenAddress();

//         if (XERC20(_xerc20).owner() != msg.sender)
//             revert IXERC20Factory_NotOwner();

//         _lockbox = _deployLockbox(_xerc20, _baseToken, _isNative);

//         emit LockboxDeployed(_lockbox);
//     }

//     /**
//      * @notice Deploys an XERC20 contract using CREATE3
//      * @dev _limits and _minters must be the same length
//      * @param _name The name of the token
//      * @param _symbol The symbol of the token
//      * @return _xerc20 The address of the xerc20
//      */
//     function _deployXERC20(
//         string memory _name,
//         string memory _symbol
//     ) internal returns (address _xerc20) {
//         address deployer = msg.sender;
//         bytes32 _salt = keccak256(abi.encodePacked(_name, _symbol, deployer));
//         bytes memory _creation = type(XERC20).creationCode;
//         bytes memory _bytecode = abi.encodePacked(
//             _creation,
//             abi.encode(_name, _symbol, address(this))
//         );

//         _xerc20 = CREATE3.deploy(_salt, _bytecode, 0);

//         XERC20(_xerc20).transferOwnership(deployer);
//     }

//     /**
//      * @notice Deploys an XERC20Lockbox contract using CREATE3
//      *
//      * @dev When deploying a lockbox for the gas token of the chain, then, the base token needs to be address(0)
//      * @param _xerc20 The address of the xerc20 that you want to deploy a lockbox for
//      * @param _baseToken The address of the base token that you want to lock
//      * @param _isNative Whether or not the base token is the native (gas) token of the chain. Eg: MATIC for polygon chain
//      * @return _lockbox The address of the lockbox
//      */
//     function _deployLockbox(
//         address _xerc20,
//         address _baseToken,
//         bool _isNative
//     ) internal returns (address _lockbox) {
//         address deployer = msg.sender;
//         bytes32 _salt = keccak256(
//             abi.encodePacked(_xerc20, _baseToken, deployer)
//         );
//         bytes memory _bytecode = abi.encodePacked(
//             type(XERC20Lockbox).creationCode,
//             abi.encode(_xerc20, _baseToken, _isNative)
//         );

//         _lockbox = CREATE3.deploy(_salt, _bytecode, 0);

//         XERC20(_xerc20).setLockbox(_lockbox);
//     }

//     function deployCreate3(
//         bytes calldata creationCode,
//         bytes32 _salt
//     ) external returns (address) {
//         return _deployCreate3(creationCode, _salt);
//     }

//     function _deployCreate3(
//         bytes memory bytecode,
//         bytes32 _salt
//     ) internal returns (address) {
//         address addr = CREATE3.deploy(_salt, bytecode, 0);

//         emit ContractCreated(addr);
//         return addr;
//     }
// }
