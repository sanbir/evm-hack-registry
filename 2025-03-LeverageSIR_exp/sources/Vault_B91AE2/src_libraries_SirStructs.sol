// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library SirStructs {
    struct VaultIssuanceParams {
        uint8 tax; // (tax / type(uint8).max * 10%) of its fee revenue is directed to the Treasury.
        uint40 timestampLastUpdate; // timestamp of the last time cumulativeSIRPerTEAx96 was updated. 0 => use systemParams.timestampIssuanceStart instead
        uint176 cumulativeSIRPerTEAx96; // Q104.96, cumulative SIR minted by the vaultId per unit of TEA.
    }

    struct VaultParameters {
        address debtToken;
        address collateralToken;
        int8 leverageTier;
    }

    struct FeeStructure {
        uint16 fee; // Fee in basis points.
        uint16 feeNew; // New fee to replace fee if current time exceeds FEE_CHANGE_DELAY since timestampUpdate
        uint40 timestampUpdate; // Timestamp fee change was made. If 0, feeNew is not used.
    }

    struct SystemParameters {
        FeeStructure baseFee;
        FeeStructure lpFee;
        bool mintingStopped; // If true, no minting of TEA/APE
        /** Aggregated taxes for all vaults. Choice of uint16 type.
            For vault i, (tax_i / type(uint8).max)*10% is charged, where tax_i is of type uint8.
            They must satisfy the condition
                Σ_i (tax_i / type(uint8).max)^2 ≤ 0.1^2
            Under this constraint, cumulativeTax = Σ_i tax_i is maximized when all taxes are equal (tax_i = tax for all i) and
                tax = type(uint8).max / sqrt(Nvaults)
            Since the lowest non-zero value is tax=1, the maximum number of vaults with non-zero tax is
                Nvaults = type(uint8).max^2 < type(uint16).max
         */
        uint16 cumulativeTax;
    }

    /** Collateral owned by the apes and LPers in a vault
     */
    struct Reserves {
        uint144 reserveApes;
        uint144 reserveLPers;
        int64 tickPriceX42;
    }

    /** Data needed for recoverying the amount of collateral owned by the apes and LPers in a vault
     */
    struct VaultState {
        uint144 reserve; // reserve =  reserveApes + reserveLPers
        /** Price at the border of the power and saturation zone.
            Q21.42 - Fixed point number with 42 bits of precision after the comma.
            type(int64).max and type(int64).min are used to represent +∞ and -∞ respectively.
         */
        int64 tickPriceSatX42; // Saturation price in Q21.42 fixed point
        uint48 vaultId; // Allows the creation of approximately 281 trillion vaults
    }

    /** The sum of all amounts in Fees are equal to the amounts deposited by the user (in the case of a mint)
        or taken out by the user (in the case of a burn).
        collateralInOrWithdrawn: Amount of collateral deposited by the user (in the case of a mint) or taken out by the user (in the case of a burn).
        collateralFeeToStakers: Amount of collateral paid to the stakers.
        collateralFeeToLPers: Amount of collateral paid to the gentlemen.
        collateralFeeToProtocol: Amount of collateral paid to the protocol.
     */
    struct Fees {
        uint144 collateralInOrWithdrawn;
        uint144 collateralFeeToStakers;
        uint144 collateralFeeToLPers; // Sometimes all LPers and sometimes only protocol owned liquidity
    }

    struct StakingParams {
        uint80 stake; // Amount of staked SIR
        uint176 cumulativeETHPerSIRx80; // Cumulative ETH per SIR * 2^80
    }

    struct StakerParams {
        uint80 stake; // Total amount of staked SIR by the staker
        uint176 cumulativeETHPerSIRx80; // Cumulative ETH per SIR * 2^80 last time the user updated his balance of ETH dividends
        uint80 lockedStake; // Amount of stake that was locked at time 'tsLastUpdate'
        uint40 tsLastUpdate; // Timestamp of the last time the user staked or unstaked
    }

    struct Auction {
        address bidder; // Address of the bidder
        uint96 bid; // Amount of the bid
        uint40 startTime; // Auction start time
    }

    struct OracleState {
        int64 tickPriceX42; // Last stored price. Q21.42
        uint40 timeStampPrice; // Timestamp of the last stored price
        uint8 indexFeeTier; // Uniswap v3 fee tier currently being used as oracle
        uint8 indexFeeTierProbeNext; // Uniswap v3 fee tier to probe next
        uint40 timeStampFeeTier; // Timestamp of the last probed fee tier
        bool initialized; // Whether the oracle has been initialized
        UniswapFeeTier uniswapFeeTier; // Uniswap v3 fee tier currently being used as oracle
    }

    /**
     * Parameters of a Uniswap v3 tier.
     */
    struct UniswapFeeTier {
        uint24 fee;
        int24 tickSpacing;
    }
}
