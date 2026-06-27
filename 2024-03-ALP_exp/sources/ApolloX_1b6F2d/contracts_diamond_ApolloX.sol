// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {LibDiamond} from "./libraries/LibDiamond.sol";
import {IDiamondCut} from "./interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "./interfaces/IDiamondLoupe.sol";
import {LibAccessControlEnumerable} from  "./libraries/LibAccessControlEnumerable.sol";

contract ApolloX {

    constructor(address admin, address deployer, address _diamondCutFacet, address _diamondLoupeFacet, address _init) payable {
        LibAccessControlEnumerable.grantRole(LibAccessControlEnumerable.DEFAULT_ADMIN_ROLE, admin);
        LibAccessControlEnumerable.grantRole(LibAccessControlEnumerable.DEPLOYER_ROLE, deployer);

        // Add the diamondCut external function from the diamondCutFacet
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](2);
        bytes4[] memory functionSelectors = new bytes4[](1);
        functionSelectors[0] = IDiamondCut.diamondCut.selector;
        cut[0] = IDiamondCut.FacetCut({
            facetAddress : _diamondCutFacet,
            action : IDiamondCut.FacetCutAction.Add,
            functionSelectors : functionSelectors
        });

        bytes4[] memory loupeFunctionSelectors = new bytes4[](4);
        loupeFunctionSelectors[0] = IDiamondLoupe.facets.selector;
        loupeFunctionSelectors[1] = IDiamondLoupe.facetAddresses.selector;
        loupeFunctionSelectors[2] = IDiamondLoupe.facetAddress.selector;
        loupeFunctionSelectors[3] = IDiamondLoupe.facetFunctionSelectors.selector;
        cut[1] = IDiamondCut.FacetCut({
            facetAddress : _diamondLoupeFacet,
            action : IDiamondCut.FacetCutAction.Add,
            functionSelectors : loupeFunctionSelectors
        });
        LibDiamond.diamondCut(cut, _init, abi.encodeWithSignature("init()"));
    }

    // Find facet for function that is called and execute the
    // function if a facet is found and return any value.
    fallback() external payable {
        LibDiamond.DiamondStorage storage ds;
        bytes32 position = LibDiamond.DIAMOND_STORAGE_POSITION;
        // get diamond storage
        assembly {
            ds.slot := position
        }
        // get facet from function selector
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        require(facet != address(0), "Diamond: Function does not exist");
        // Execute external function from facet using delegatecall and return any value.
        assembly {
            // copy function selector and any arguments
            calldatacopy(0, 0, calldatasize())
            // execute function call using the facet
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            // get any return value
            returndatacopy(0, 0, returndatasize())
            // return any return value or error back to the caller
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return (0, returndatasize())
            }
        }
    }

    receive() external payable {}
}
