// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";

// Libraries
import {SirStructs} from "./SirStructs.sol";
import {TickMathPrecision} from "./TickMathPrecision.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {SystemConstants} from "./SystemConstants.sol";
import {ClonesWithImmutableArgs} from "lib/clones-with-immutable-args/src/ClonesWithImmutableArgs.sol";

// Contracts
import {Oracle} from "../Oracle.sol";

library VaultExternal {
    error VaultAlreadyInitialized();
    error LeverageTierOutOfRange();
    error VaultDoesNotExist();

    event VaultInitialized(
        address indexed debtToken,
        address indexed collateralToken,
        int8 indexed leverageTier,
        uint256 vaultId,
        address ape
    );

    // Deploy APE token
    function deploy(
        Oracle oracle,
        SirStructs.VaultState storage vaultState,
        SirStructs.VaultParameters[] storage paramsById,
        SirStructs.VaultParameters calldata vaultParams,
        address implementationOfAPE
    ) external {
        if (
            vaultParams.leverageTier > SystemConstants.MAX_LEVERAGE_TIER ||
            vaultParams.leverageTier < SystemConstants.MIN_LEVERAGE_TIER
        ) revert LeverageTierOutOfRange();

        /**
         * 1. This will initialize the oracle for this pair of tokens if it has not been initialized before.
         * 2. It also will revert if there are no pools with liquidity, which implicitly solves the case where the user
         *    tries to instantiate an invalid pair of tokens like address(0)
         */
        oracle.initialize(vaultParams.debtToken, vaultParams.collateralToken);

        // Check the vault has not been initialized previously
        if (vaultState.vaultId != 0) revert VaultAlreadyInitialized();

        // Next vault ID
        uint256 vaultId = paramsById.length;
        require(vaultId <= type(uint48).max); // It has to fit in a uint48

        // Save parameters
        paramsById.push(vaultParams);

        // Derive the name of the APE clone
        string memory name = _generateName(vaultParams);

        // Derive the future address of the APE clone
        address ape = ClonesWithImmutableArgs.addressOfClone3(bytes32(vaultId));

        // Compute the default domain separator for the APE clone
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256("1"),
                block.chainid,
                ape
            )
        );

        // Deploy APE clone
        ClonesWithImmutableArgs.clone3(
            implementationOfAPE,
            abi.encodePacked(
                vaultParams.leverageTier, // The clone needs to know the leverage tier when minting/burning
                address(this), // So the clone knows the owner
                domainSeparator // This way the domain separator is stored as a constant
            ),
            bytes32(vaultId)
        );

        // Initialize APE clone
        (bool success, ) = ape.call(
            abi.encodeWithSignature(
                "initialize(string,string,uint8,address,address)",
                name,
                string.concat("APE-", Strings.toString(vaultId)),
                IERC20(vaultParams.collateralToken).decimals(),
                vaultParams.debtToken,
                vaultParams.collateralToken
            )
        );
        require(success);

        // Save vaultId
        vaultState.vaultId = uint48(vaultId);

        emit VaultInitialized(
            vaultParams.debtToken,
            vaultParams.collateralToken,
            vaultParams.leverageTier,
            vaultId,
            ape
        );
    }

    function teaURI(
        SirStructs.VaultParameters[] storage paramsById,
        uint256 vaultId,
        uint256 totalSupply
    ) external view returns (string memory) {
        string memory vaultIdStr = Strings.toString(vaultId);

        SirStructs.VaultParameters memory params = paramsById[vaultId];
        require(vaultId != 0);

        return
            string.concat(
                "data:application/json;charset=UTF-8,%7B%22name%22%3A%22LP%20Token%20for%20APE-",
                vaultIdStr,
                "%22%2C%22symbol%22%3A%22TEA-",
                vaultIdStr,
                "%22%2C%22decimals%22%3A",
                Strings.toString(IERC20(params.collateralToken).decimals()),
                "%2C%22chain_id%22%3A1%2C%22vault_id%22%3A",
                vaultIdStr,
                "%2C%22debt_token%22%3A%22",
                Strings.toHexString(params.debtToken),
                "%22%2C%22collateral_token%22%3A%22",
                Strings.toHexString(params.collateralToken),
                "%22%2C%22leverage_tier%22%3A",
                Strings.toStringSigned(params.leverageTier),
                "%2C%22total_supply%22%3A",
                Strings.toString(totalSupply),
                "%7D"
            );
    }

    function getReservesReadOnly(
        mapping(address debtToken => mapping(address collateralToken => mapping(int8 leverageTier => SirStructs.VaultState)))
            storage _vaultStates,
        Oracle oracle,
        SirStructs.VaultParameters calldata vaultParams
    ) external view returns (SirStructs.Reserves memory reserves) {
        // Get price
        reserves.tickPriceX42 = oracle.getPrice(vaultParams.collateralToken, vaultParams.debtToken);

        _getReserves(
            _vaultStates[vaultParams.debtToken][vaultParams.collateralToken][vaultParams.leverageTier],
            reserves,
            vaultParams.leverageTier
        );
    }

    function getReserves(
        bool isAPE,
        mapping(address debtToken => mapping(address collateralToken => mapping(int8 leverageTier => SirStructs.VaultState)))
            storage _vaultStates,
        Oracle oracle,
        SirStructs.VaultParameters calldata vaultParams
    )
        external
        returns (
            SirStructs.VaultState memory vaultState,
            SirStructs.Reserves memory reserves,
            address ape,
            address uniswapPool
        )
    {
        unchecked {
            vaultState = _vaultStates[vaultParams.debtToken][vaultParams.collateralToken][vaultParams.leverageTier];

            // Get price and update oracle state if needed
            (reserves.tickPriceX42, uniswapPool) = oracle.updateOracleState(
                vaultParams.collateralToken,
                vaultParams.debtToken
            );

            // Derive APE address if needed
            if (isAPE) ape = ClonesWithImmutableArgs.addressOfClone3(bytes32(uint256(vaultState.vaultId)));

            _getReserves(vaultState, reserves, vaultParams.leverageTier);
        }
    }

    /*////////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function _generateName(SirStructs.VaultParameters calldata vaultParams) private view returns (string memory) {
        string memory leverageStr;
        if (vaultParams.leverageTier == -4) leverageStr = "1.0625";
        else if (vaultParams.leverageTier == -3) leverageStr = "1.125";
        else if (vaultParams.leverageTier == -2) leverageStr = "1.25";
        else if (vaultParams.leverageTier == -1) leverageStr = "1.5";
        else if (vaultParams.leverageTier == 0) leverageStr = "2";
        else if (vaultParams.leverageTier == 1) leverageStr = "3";
        else if (vaultParams.leverageTier == 2) leverageStr = "5";

        return
            string(
                abi.encodePacked(
                    "Tokenized ",
                    IERC20(vaultParams.collateralToken).symbol(),
                    "/",
                    IERC20(vaultParams.debtToken).symbol(),
                    " with ",
                    leverageStr,
                    "x leverage"
                )
            );
    }

    function _getReserves(
        SirStructs.VaultState memory vaultState,
        SirStructs.Reserves memory reserves,
        int8 leverageTier
    ) private pure {
        unchecked {
            if (vaultState.vaultId == 0) revert VaultDoesNotExist();

            // Reserve is empty only in the 1st mint
            if (vaultState.reserve != 0) {
                assert(vaultState.reserve >= 1e6);

                if (vaultState.tickPriceSatX42 == type(int64).min) {
                    // type(int64).min represents -∞ => reserveLPers = 0
                    reserves.reserveApes = vaultState.reserve - 1;
                    reserves.reserveLPers = 1;
                } else if (vaultState.tickPriceSatX42 == type(int64).max) {
                    // type(int64).max represents +∞ => reserveApes = 0
                    reserves.reserveApes = 1;
                    reserves.reserveLPers = vaultState.reserve - 1;
                } else {
                    bool isLeverageTierNonNegative = leverageTier >= 0;
                    uint8 absLeverageTier = isLeverageTierNonNegative ? uint8(leverageTier) : uint8(-leverageTier);

                    if (reserves.tickPriceX42 < vaultState.tickPriceSatX42) {
                        /**
                         * POWER ZONE
                         * A = (price/priceSat)^(l-1) R/l
                         * price = 1.0001^tickPriceX42 and priceSat = 1.0001^tickPriceSatX42
                         * We use the fact that l = 1+2^leverageTier
                         * reserveApes is rounded up
                         */
                        int256 poweredTickPriceDiffX42 = isLeverageTierNonNegative
                            ? (int256(vaultState.tickPriceSatX42) - reserves.tickPriceX42) << absLeverageTier
                            : (int256(vaultState.tickPriceSatX42) - reserves.tickPriceX42) >> absLeverageTier;

                        if (poweredTickPriceDiffX42 > SystemConstants.MAX_TICK_X42) {
                            reserves.reserveApes = 1;
                        } else {
                            /** Rounds up reserveApes, rounds down reserveLPers.
                                Cannot overflow.
                                64 bits because getRatioAtTick returns a Q64.64 number.
                            */
                            uint256 poweredPriceRatioX64 = TickMathPrecision.getRatioAtTick(
                                int64(poweredTickPriceDiffX42)
                            );

                            reserves.reserveApes = uint144(
                                _divRoundUp(
                                    uint256(vaultState.reserve) <<
                                        (isLeverageTierNonNegative ? 64 : 64 + absLeverageTier),
                                    poweredPriceRatioX64 + (poweredPriceRatioX64 << absLeverageTier)
                                )
                            );

                            if (reserves.reserveApes == vaultState.reserve) reserves.reserveApes--;
                            assert(reserves.reserveApes != 0); // It should never be 0 because it's rounded up. Important for the protocol that it is at least 1.
                        }

                        reserves.reserveLPers = vaultState.reserve - reserves.reserveApes;
                    } else {
                        /**
                         * SATURATION ZONE
                         * LPers are 100% pegged to debt token.
                         * L = (priceSat/price) R/r
                         * price = 1.0001^tickPriceX42 and priceSat = 1.0001^tickPriceSatX42
                         * We use the fact that lr = 1+2^-leverageTier
                         * reserveLPers is rounded up
                         */
                        int256 tickPriceDiffX42 = int256(reserves.tickPriceX42) - vaultState.tickPriceSatX42;

                        if (tickPriceDiffX42 > SystemConstants.MAX_TICK_X42) {
                            reserves.reserveLPers = 1;
                        } else {
                            /** Rounds up reserveLPers, rounds down reserveApes.
                                Cannot overflow.
                                64 bits because getRatioAtTick returns a Q64.64 number.
                            */
                            uint256 priceRatioX64 = TickMathPrecision.getRatioAtTick(int64(tickPriceDiffX42));

                            reserves.reserveLPers = uint144(
                                _divRoundUp(
                                    uint256(vaultState.reserve) <<
                                        (isLeverageTierNonNegative ? 64 + absLeverageTier : 64),
                                    priceRatioX64 + (priceRatioX64 << absLeverageTier)
                                )
                            );

                            if (reserves.reserveLPers == vaultState.reserve) reserves.reserveLPers--;
                            assert(reserves.reserveLPers != 0); // It should never be 0 because it's rounded up. Important for the protocol that it is at least 1.
                        }

                        reserves.reserveApes = vaultState.reserve - reserves.reserveLPers;
                    }
                }
            }
        }
    }

    function _divRoundUp(uint256 a, uint256 b) private pure returns (uint256) {
        unchecked {
            return (a - 1) / b + 1;
        }
    }
}
