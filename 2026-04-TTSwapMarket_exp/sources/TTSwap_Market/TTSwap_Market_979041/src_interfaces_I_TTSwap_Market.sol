// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title Market Management Interface
/// @notice Defines the interface for managing market operations
interface I_TTSwap_Market {
    /// @notice Emitted when a good's configuration is updated
    /// @param _goodid The ID of the good
    /// @param _goodConfig The new configuration
    event e_updateGoodConfig(address _goodid, uint256 _goodConfig,address _trader);

    /// @notice Emitted when a good's configuration is modified by market admin
    /// @param _goodid The ID of the good
    /// @param _goodconfig The new configuration
    event e_modifyGoodConfig(address _goodid, uint256 _goodconfig,address _trader);

    /// @notice Emitted when a good's owner is changed
    /// @param goodid The ID of the good
    /// @param to The new owner's address
    event e_changegoodowner(address goodid, address to,address _trader);

    /// @notice Emitted when market commission is collected
    /// @param _gooid Array of good IDs
    /// @param _commisionamount Array of commission amounts
    event e_collectcommission(address[] _gooid, uint256[] _commisionamount,address _trader);

    /// @notice Emitted when welfare is delivered to investors
    /// @param goodid The ID of the good
    /// @param welfare The amount of welfare
    event e_goodWelfare(address goodid, uint128 welfare,address _trader);

    /// @notice Emitted when a meta good is created and initialized
    /// @dev The decimal precision of _initial.amount0() defaults to 6
    /// @param _proofNo The ID of the investment proof
    /// @param _goodid A 256-bit value where the first 128 bits represent the good's ID and the last 128 bits represent the stake construct
    /// @param _construct The stake construct of mint tts token
    /// @param _goodConfig The configuration of the meta good (refer to the whitepaper for details)
    /// @param _initial Market initialization parameters: amount0 is the value, amount1 is the quantity
    event e_initMetaGood(
        uint256 _proofNo,
        address _goodid,
        uint256 _construct,
        uint256 _goodConfig,
        uint256 _initial
    );

    /// @notice Emitted when a good is created and initialized
    /// @param _proofNo The ID of the investment proof
    /// @param _goodid The ID of the good
    /// @param _valuegoodNo The ID of the good
    /// @param _goodConfig The configuration of the meta good (refer to the whitepaper for details)
    /// @param _construct The stake construct of mint tts token
    /// @param _normalinitial Normal good initialization parameters: amount0 is the quantity, amount1 is the value
    /// @param _value Value good initialization parameters: amount0 is the investment fee, amount1 is the investment quantity
    event e_initGood(
        uint256 _proofNo,
        address _goodid,
        address _valuegoodNo,
        uint256 _goodConfig,
        uint256 _construct,
        uint256 _normalinitial,
        uint256 _value,
        address _trader
    );

    /// @notice Emitted when a user buys a good
    /// @param sellgood The ID of the good being sold
    /// @param forgood The ID of the good being bought
    /// @param swapvalue The trade value
    /// @param good1change The status of the sold good (amount0: fee, amount1: quantity)
    /// @param good2change The status of the bought good (amount0: fee, amount1: quantity)
    event e_buyGood(
        address indexed sellgood,
        address indexed forgood,
        uint256 swapvalue,
        uint256 good1change,
        uint256 good2change,
        address _trader
    );
    /// @notice Emitted when a user makes a payment using goods
    /// @param sellgood The ID of the good being sold/used for payment
    /// @param forgood The ID of the good being received
    /// @param swapvalue The trade value
    /// @param good1change The status of the sold good (amount0: fee, amount1: quantity)
    /// @param good2change The status of the received good (amount0: fee, amount1: quantity)
    /// @param _trader The address of the trader initiating the payment
    /// @param data_hash The hash of the transaction data for verification
    event e_payGood(
        address indexed sellgood,
        address indexed forgood,
        uint256 swapvalue,
        uint256 good1change,
        uint256 good2change,
        address _trader,
        address _recipient,
        uint256 data_hash
    );


    /// @notice Emitted when a user invests in a normal good
    /// @param _proofNo The ID of the investment proof
    /// @param _normalgoodid Packed data: first 128 bits for good's ID, last 128 bits for stake construct
    /// @param _valueGoodNo The ID of the value good
    /// @param _value Investment value (amount0: virtual invest value, amount1: actual invest value)
    /// @param _invest Normal good investment details (amount0: actual fee, amount1: actual invest quantity)
    /// @param _valueinvest Value good investment details (amount0: actual fee, amount1: actual invest quantity)
    event e_investGood(
        uint256 indexed _proofNo,
        address _normalgoodid,
        address _valueGoodNo,
        uint256 _value,
        uint256 _invest,
        uint256 _valueinvest,
        address _trader
    );

    /// @notice Emitted when a user disinvests from  good
    /// @param _proofNo The ID of the investment proof
    /// @param _normalGoodNo The ID of the normal good
    /// @param _valueGoodNo The ID of the value good
    /// @param _gate The gate of User
    /// @param _value amount0: virtual disinvest value,amount1: actual disinvest value
    /// @param _normalprofit amount0:normalgood profit,amount1:normalgood disvest virtual quantity
    /// @param _normaldisvest The disinvestment details of the normal good (amount0: actual fee, amount1: actual disinvest quantity)
    /// @param _valueprofit amount0:valuegood profit,amount1:valuegood disvest virtual quantity
    /// @param _valuedisvest The disinvestment details of the value good (amount0: actual fee, amount1: actual disinvest quantity)
    event e_disinvestProof(
        uint256 indexed _proofNo,
        address _normalGoodNo,
        address _valueGoodNo,
        address _gate,
        uint256 _value,
        uint256 _normalprofit,
        uint256 _normaldisvest,
        uint256 _valueprofit,
        uint256 _valuedisvest,
        address _trader
    );

    event e_getPromiseProof(
        address _goodid,
        uint256 _proofid
    );

    /// @notice Initialize the first good in the market
    /// @param _erc20address The contract address of the good
    /// @param _initial Initial parameters for the good (amount0: value, amount1: quantity)
    /// @param _goodconfig Configuration of the good
    /// @param data Configuration of the good
    /// @return Success status
    function initMetaGood(
        address _erc20address,
        uint256 _initial,
        uint256 _goodconfig,
        bytes calldata data
    ) external payable returns (bool);

    /// @notice Initialize a normal good in the market
    /// @param _valuegood The ID of the value good used to measure the normal good's value
    /// @param _initial Initial parameters (amount0: normal good quantity, amount1: value good quantity)
    /// @param _erc20address The contract address of the good
    /// @param _goodConfig Configuration of the good
    /// @param data1 Configuration of the good
    /// @param data2 Configuration of the good
    /// @return Success status
    function initGood(
        address _valuegood,
        uint256 _initial,
        address _erc20address,
        uint256 _goodConfig,
        bytes calldata data1,
        bytes calldata data2,
        address _trader,
        bytes calldata signature
    ) external payable returns (bool);

    /**
     * @dev Buys a good
     * @param _goodid1 The ID of the first good
     * @param _goodid2 The ID of the second good
     * @param _swapQuantity The amount of _goodid1 to swap
     *        - amount0: The quantity of the input good
     *        - amount1: The limit quantity of the output good
     * @param _referal when side is buy, _referal is the referral address when side is sell, _referal is the address to receive the fee
     * @return good1change amount0() good1tradefee,good1tradeamount
     * @return good2change amount0() good1tradefee,good2tradeamount
     */
    function buyGood(
        address _goodid1,
        address _goodid2,
        uint256 _swapQuantity,
        address _referal,
        bytes calldata data,
        address _trader,
        bytes calldata signature
    ) external payable returns (uint256 good1change, uint256 good2change);

    function payGood(
        address _goodid1,
        address _goodid2,
        uint256 _swapQuantity,
        address _recipient,
        bytes calldata data,
        address _trader,
        bytes calldata signature,
        uint256 data_hash
    ) external payable returns (uint256 good1change, uint256 good2change);

    /// @notice Invest in a normal good
    /// @param _togood ID of the normal good to invest in
    /// @param _valuegood ID of the value good
    /// @param _quantity Quantity of normal good to invest
    /// @return Success status
    function investGood(
        address _togood,
        address _valuegood,
        uint128 _quantity,
        bytes calldata data1,
        bytes calldata data2,
        address _trader,
        bytes calldata signature
    ) external payable returns (bool);

    /// @notice Disinvest from a normal good
    /// @param _proofid ID of the investment proof
    /// @param _goodQuantity Quantity to disinvest
    /// @param _gate Address of the gate
    /// @return reward1 status
    /// @return reward2 status
    function disinvestProof(
        uint256 _proofid,
        uint128 _goodQuantity,
        address _gate,
        address _trader,
        bytes calldata signature
    ) external returns (uint128 reward1, uint128 reward2);

    /// @notice Check if the price of a good is higher than a comparison price
    /// @param goodid ID of the good to check
    /// @param valuegood ID of the value good
    /// @param compareprice Price to compare against
    /// @return Whether the good's price is higher
    function ishigher(
        address goodid,
        address valuegood,
        uint256 compareprice
    ) external view returns (bool);

    function refreshPromise(uint256 _proofid) external   ;

    /// @notice Retrieves the current state of a proof
    /// @param proofid The ID of the proof to query
    /// @return proofstate The current state of the proof,
    ///  currentgood The current good associated with the proof
    ///  valuegood The value good associated with the proof
    ///  shares normal good shares, value good shares
    ///  state Total value, Total actual value
    ///  invest normal good virtual quantity, normal good actual quantity
    ///  valueinvest value good virtual quantity, value good actual quantity
    function getProofState(
        uint256 proofid
    ) external view returns (S_ProofState memory);

    /// @notice Retrieves the current state of a good
    /// @param good The address of the good to query
    /// @return goodstate The current state of the good,
    ///  goodConfig Configuration of the good, check goodconfig.sol or whitepaper for details
    ///  owner Creator of the good
    ///  currentState Present investQuantity, CurrentQuantity
    ///  investState Shares, value
    function getGoodState(
        address good
    ) external view returns (S_GoodTmpState memory);

    /// @notice Updates a good's configuration
    /// @param _goodid The ID of the good
    /// @param _goodConfig The new configuration
    /// @return Success status
    function updateGoodConfig(
        address _goodid,
        uint256 _goodConfig,
        address _trader,
        bytes calldata signature
    ) external returns (bool);

    /// @notice Allows market admin to modify a good's attributes
    /// @param _goodid The ID of the good
    /// @param _goodConfig The new configuration
    /// @return Success status
    function modifyGoodConfig(
        address _goodid,
        uint256 _goodConfig,
        address _trader,
        bytes calldata signature
    ) external returns (bool);

    // @param _goodid The ID of the good
    /// @param _goodConfig The new configuration
    /// @return Success status
    function modifyGoodCoreConfig(
        address _goodid,
        uint256 _goodConfig,
        address _trader,
        bytes calldata signature
    ) external returns (bool);

    function lockGood(
        address _goodid,
        address _trader,
        bytes calldata signature
    ) external;

    /// @notice Changes the owner of a good
    /// @param _goodid The ID of the good
    /// @param _to The new owner's address
    function changeGoodOwner(
        address _goodid,
        address _to,
        address _trader,
        bytes calldata signature
    ) external;

    /// @notice Collects commission for specified goods
    /// @param _goodid Array of good IDs
    function collectCommission(
        address[] calldata _goodid,
        address _trader,
        bytes calldata signature
    ) external;

    /**
     * @dev Queries commission amounts for multiple goods for a specific recipient
     * @param _goodid Array of good addresses to query commission for
     * @param _recipient The address to check commission amounts for
     * @return feeamount Array of commission amounts corresponding to each good
     * @notice This function:
     * - Returns commission amounts for up to 100 goods in a single call
     * - Each amount represents the commission available for the recipient
     * - Returns 0 for goods where no commission is available
     * - Maintains gas efficiency by using a fixed array size
     * @custom:security Reverts if more than 100 goods are queried
     * @custom:security View function, does not modify state
     */
    function queryCommission(
        address[] calldata _goodid,
        address _recipient
    ) external returns (uint256[] memory);

    /// @notice Delivers welfare to investors
    /// @param goodid The ID of the good
    /// @param welfare The amount of welfare
    function goodWelfare(
        address goodid,
        uint128 welfare,
        bytes calldata data1,
        address _trader,
        bytes calldata signature
    ) external payable;

    /**
     * @notice Retrieves the current state of two goods in a single call
     * @dev Retrieves the current state of two goods in a single call
     * @param good1 The address of the first good to query
     * @param good2 The address of the second good to query
     * @return good1correntstate The current state of the first good, representing its latest trading iteration,amount0:good current value,amount1:good current quantity
     * @return good2correntstate The current state of the second good, representing its latest trading iteration,amount0:good current value,amount1:good current quantity
     */
    function getRecentGoodState(
        address good1,
        address good2
    )
        external
        view
        returns (uint256 good1correntstate, uint256 good2correntstate);
}

/**
 * @dev Represents the state of a proof.
 * @notice Fields:
 * - `currentgood`: The current good associated with the proof
 * - `valuegood`: The value good associated with the proof
 * - `shares`: amount0 = normal good shares, amount1 = value good shares
 * - `state`: amount0 = total value, amount1 = total actual value
 * - `invest`: amount0 = normal good virtual quantity, amount1 = normal good actual quantity
 * - `valueinvest`: amount0 = value good virtual quantity, amount1 = value good actual quantity
 */
struct S_ProofState {
    address currentgood;
    address valuegood;
    uint256 shares;
    uint256 state;
    uint256 invest;
    uint256 valueinvest;
}

/**
 * @dev Struct representing the state of a good.
 * @notice Fields:
 * - `goodConfig`: amount0 = configuration settings, amount1 = total virtual quantity
 * - `owner`: Creator of the good
 * - `currentState`: Present invest quantity and current quantity
 * - `investState`: Shares and value aggregates
 */
struct S_GoodState {
    uint256 goodConfig;
    address owner;
    uint256 currentState;
    uint256 investState;
    uint256 extendsState1;
    uint256 extendsState2;
    uint256 extendsState3;
    uint256 extendsState4;
    uint256 extendsState5;
    uint256 extendsState6;
    uint256 extendsState7;
    uint256 extendsState8;
    uint256 extendsState9;
    mapping(address => uint256) commission;
    mapping(address => uint256) extendmapping1;
    mapping(address => uint256) extendmapping2;
    mapping(address => uint256) extendmapping3;
    mapping(address => uint256) extendmapping4;
    mapping(address => uint256) extendmapping5;
}

/**
 * @dev Struct representing a temporary state of a good.
 * @notice Fields mirror `S_GoodState` but store lightweight snapshots:
 * - `goodConfig`: amount0 = configuration settings, amount1 = total virtual quantity
 * - `owner`: Creator of the good
 * - `currentState`: Present invest quantity and current quantity
 * - `investState`: Shares and value aggregates
 */
struct S_GoodTmpState {
    uint256 goodConfig;
    address owner;
    uint256 currentState;
    uint256 investState;
}

/**
 * @dev Struct representing a key of a proof.
 * @notice Fields:
 * - `owner`: The owner of the proof
 * - `currentgood`: The current good associated with the proof
 * - `valuegood`: The value good associated with the proof
 */
struct S_ProofKey {
    address owner;
    address currentgood;
    address valuegood;
}
