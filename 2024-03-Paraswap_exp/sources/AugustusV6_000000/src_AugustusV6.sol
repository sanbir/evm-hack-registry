// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Vendor
import { Diamond } from "./vendor/Diamond.sol";

// Routers
import { Routers } from "./routers/Routers.sol";

//                  ______                                   __                     __  __    ____
//                 /\  _  \                                 /\ \__                 /\ \/\ \  /'___\
//                 \ \ \L\ \  __  __     __   __  __    ____\ \ ,_\  __  __    ____\ \ \ \ \/\ \__/
//                  \ \  __ \/\ \/\ \  /'_ `\/\ \/\ \  /',__\\ \ \/ /\ \/\ \  /',__\\ \ \ \ \ \  _``\
//                   \ \ \/\ \ \ \_\ \/\ \L\ \ \ \_\ \/\__, `\\ \ \_\ \ \_\ \/\__, `\\ \ \_/ \ \ \L\ \
//                    \ \_\ \_\ \____/\ \____ \ \____/\/\____/ \ \__\\ \____/\/\____/ \ `\___/\ \____/
//                     \/_/\/_/\/___/  \/___L\ \/___/  \/___/   \/__/ \/___/  \/___/   `\/__/  \/___/
//                                       /\____/
//                                       \_/__/

/// @title AugustusV6
/// @notice The V6 implementation of the ParaSwap onchain aggregation protocol
contract AugustusV6 is Diamond, Routers {
    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        /// @dev Diamond
        address _owner,
        address _diamondCutFacet,
        /// @dev Direct Routers
        address _weth,
        address payable _balancerVault,
        uint256 _uniV3FactoryAndFF,
        uint256 _uniswapV3PoolInitCodeHash,
        uint256 _uniswapV2FactoryAndFF,
        uint256 _uniswapV2PoolInitCodeHash,
        address _rfq,
        /// @dev Fees
        address payable _feeVault,
        /// @dev Permit2
        address _permit2
    )
        Diamond(_owner, _diamondCutFacet)
        Routers(
            _weth,
            _uniV3FactoryAndFF,
            _uniswapV3PoolInitCodeHash,
            _uniswapV2FactoryAndFF,
            _uniswapV2PoolInitCodeHash,
            _balancerVault,
            _permit2,
            _rfq,
            _feeVault
        )
    { }

    /*//////////////////////////////////////////////////////////////
                                EXTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts if the caller is one of the following:
    //         - an externally-owned account
    //         - a contract in construction
    //         - an address where a contract will be created
    //         - an address where a contract lived, but was destroyed
    receive() external payable override(Diamond) {
        address addr = msg.sender;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            if iszero(extcodesize(addr)) { revert(0, 0) }
        }
    }
}
