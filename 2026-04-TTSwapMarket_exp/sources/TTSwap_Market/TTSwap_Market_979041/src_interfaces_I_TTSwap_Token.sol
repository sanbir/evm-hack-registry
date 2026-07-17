// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title Investment Proof Interface
/// @notice Contains a series of interfaces for goods
interface I_TTSwap_Token {
    /// @notice Emitted when environment variables are set
    /// @param marketcontract The address of the market contract
    event e_setenv(address marketcontract);

    /// @notice Emitted when user config is updated
    /// @param user The address of the user
    /// @param config The new config value
    event e_updateUserConfig(address user, uint256 config);

    /// @notice Emitted when a referral relationship is added
    /// @param user The address of the user being referred
    event e_addreferral(address user, address referal);

    /// @notice Emitted when minting is added
    /// @param recipient The address receiving the minted tokens
    /// @param leftamount The remaining amount to be minted
    /// @param metric The metric used for minting
    /// @param chips The number of chips
    event e_addShare(
        address recipient,
        uint128 leftamount,
        uint120 metric,
        uint8 chips
    );

    /// @notice Emitted when minting is burned
    /// @param owner The index of the minting operation being burned
    event e_burnShare(address owner);

    /// @notice Emitted when DAO minting occurs
    /// @param mintamount The amount being minted
    /// @param owner The index of the minting operation
    event e_shareMint(uint128 mintamount, address owner);

    /// @notice Emitted during a public sale
    /// @param usdtamount The amount of USDT involved
    /// @param ttsamount The amount of TTS involved
    event e_publicsell(uint256 usdtamount, uint256 ttsamount);

    /// @notice Emitted when chain stake is synchronized
    /// @param chain The chain ID
    /// @param poolasset The pool asset value
    /// @param proofstate  The value of the pool
    //first 128 bit proofvalue,last 128 bit proofconstruct
    event e_syncChainStake(uint32 chain, uint128 poolasset, uint256 proofstate);

    /// @notice Emitted when unstaking occurs
    /// @param recipient The address receiving the unstaked tokens
    /// @param proofvalue first 128 bit proofvalue,last 128 bit poolcontruct
    /// @param unstakestate The state after unstaking
    /// @param stakestate The state of the stake
    /// @param poolstate The state of the pool
    event e_stakeinfo(
        address recipient,
        uint256 proofvalue,
        uint256 unstakestate,
        uint256 stakestate,
        uint256 poolstate
    );
    /// @notice Emitted when the pool state is updated
    /// @param poolstate The new state of the pool
    event e_updatepool(uint256 poolstate);
    /// @notice Emitted when the pool state is updated
    /// @param ttsconfig The new state of the pool
    event e_updatettsconfig(uint256 ttsconfig);

    /**
     * @dev Returns the share information for a given user address.
     * @param user The address to query for share information.
     * @return The s_share struct containing the user's share details.
     */
    function usershares(address user) external view returns (s_share memory);

    /**
     * @dev Returns the current staking state.
     * @return The staking state as a uint256 value.
     */
    function stakestate() external view returns (uint256);

    /**
     * @dev Returns the current pool state.
     * @return The pool state as a uint256 value.
     */
    function poolstate() external view returns (uint256);

    /**
     * @dev Returns the TTS token configuration value.
     * @return The configuration as a uint256 value.
     */
    function ttstokenconfig() external view returns (uint256);

    /**
     * @dev Returns the amount of left share available for minting.
     * @return The left share as a uint128 value.
     */
    function left_share() external view returns (uint128);

    /**
     * @dev Returns the stake proof information for a given index.
     * @param index The index to query for stake proof information.
     * @return The s_proof struct containing the stake proof details.
     */
    function stakeproofinfo(uint256 index) external view returns (s_proof memory);

    /**
     * @dev Sets the trading volume ratio for the protocol.
     * @param _ratio The new ratio value (max 10000).
     */
    function setRatio(uint256 _ratio) external;

    /**
     * @dev Grants or revokes DAO admin privileges to a recipient address.
     * @param _recipient The address to grant or revoke DAO admin rights.
     * @param result Boolean indicating whether to grant (true) or revoke (false) the privilege.
     */
    function setDAOAdmin(address _recipient, bool result) external;

    /**
     * @dev Grants or revokes Token admin privileges to a recipient address.
     * @param _recipient The address to grant or revoke Token admin rights.
     * @param result Boolean indicating whether to grant (true) or revoke (false) the privilege.
     */
    function setTokenAdmin(address _recipient, bool result) external;

    /**
     * @dev Grants or revokes Token manager privileges to a recipient address.
     * @param _recipient The address to grant or revoke Token manager rights.
     * @param result Boolean indicating whether to grant (true) or revoke (false) the privilege.
     */
    function setTokenManager(address _recipient, bool result) external;

    /**
     * @dev Grants or revokes permission to call mintTTS to a recipient address.
     * @param _recipient The address to grant or revoke permission.
     * @param result Boolean indicating whether to grant (true) or revoke (false) the privilege.
     */
    function setCallMintTTS(address _recipient, bool result) external;

    /**
     * @dev Grants or revokes Market admin privileges to a recipient address.
     * @param _recipient The address to grant or revoke Market admin rights.
     * @param result Boolean indicating whether to grant (true) or revoke (false) the privilege.
     */
    function setMarketAdmin(address _recipient, bool result) external;

    /**
     * @dev Grants or revokes Market manager privileges to a recipient address.
     * @param _recipient The address to grant or revoke Market manager rights.
     * @param result Boolean indicating whether to grant (true) or revoke (false) the privilege.
     */
    function setMarketManager(address _recipient, bool result) external;

    /**
     * @dev Grants or revokes Stake admin privileges to a recipient address.
     * @param _recipient The address to grant or revoke Stake admin rights.
     * @param result Boolean indicating whether to grant (true) or revoke (false) the privilege.
     */
    function setStakeAdmin(address _recipient, bool result) external;

    /**
     * @dev Grants or revokes Stake manager privileges to a recipient address.
     * @param _recipient The address to grant or revoke Stake manager rights.
     * @param result Boolean indicating whether to grant (true) or revoke (false) the privilege.
     */
    function setStakeManager(address _recipient, bool result) external;

    /**
     * @dev Sets or unsets a ban on a recipient address, restricting their access.
     * @param _recipient The address to ban or unban.
     * @param result Boolean indicating whether to ban (true) or unban (false) the address.
     */
    function setBan(address _recipient, bool result) external;

    /**
     * @dev  Returns the amount of TTS available for public sale
     * @return _publicsell Returns the amount of TTS available for public sale
     */
    function publicsell() external view returns (uint128 _publicsell);

    /**
     * @dev Returns the authorization level for a given address
     * @param recipent user's address
     * @return _auth Returns the authorization level
     */
    function userConfig(address recipent) external view returns (uint256 _auth);

    /**
     * @dev Sets the environment variables for normal good ID, value good ID, and market contract address
     * @param _marketcontract The address of the market contract
     */
    function setEnv(address _marketcontract) external; 
    /**
     * @dev Adds a new mint share to the contract
     * @param _share The share structure containing recipient, amount, metric, and chips
     * @notice Only callable on the main chain by the DAO admin
     * @notice Reduces the left_share by the amount in _share
     * @notice Increments the shares_index and adds the new share to the shares mapping
     * @notice Emits an e_addShare event with the share details
     */
    function addShare(s_share calldata _share, address owner) external;
    /**
     * @dev  Burns the share at the specified index
     * @param owner owner of share
     */
    function burnShare(address owner) external;
    /**
     * @dev  Mints a share at the specified
     */
    function shareMint() external;
    /**
     * @dev how much cost to buy tts
     * @param usdtamount usdt amount
     */
    function publicSell(uint256 usdtamount, bytes calldata data) external;
    /**
     * @dev  Withdraws the specified amount from the public sale to the recipient
     * @param amount admin tranfer public sell to another address
     * @param recipent user's address
     */
    function withdrawPublicSell(uint256 amount, address recipent) external;

    /**
     * @dev Burns the specified value of tokens from the given account
     * @param value the amount will be burned
     */
    function burn(uint256 value) external;

    /// @notice Add a referral relationship
    /// @param user The address of the user being referred
    /// @param referral The address of the referrer
    function setReferral(address user, address referral) external;

    /// @notice Stake tokens
    /// @param staker The address of the staker
    /// @param proofvalue The proof value for the stake
    /// @return construct The construct value after staking
    function stake(
        address staker,
        uint128 proofvalue
    ) external returns (uint128 construct);

    /// @notice Unstake tokens
    /// @param staker The address of the staker
    /// @param proofvalue The proof value for unstaking
    function unstake(address staker, uint128 proofvalue) external;

    /// @notice Get the DAO admin and referral for a customer
    /// @param _customer The address of the customer
    /// @return referral The address of the referrer
    function getreferral(
        address _customer
    ) external view returns (address referral);

    /**
     * @dev Permits a share to be transferred
     * @param _share The share structure containing recipient, amount, metric, and chips
     * @param dealline The deadline for the share transfer
     * @param signature The signature of the share transfer
     * @param signer The address of the signer
     */
    function permitShare(
        s_share memory _share,
        uint128 dealline,
        bytes calldata signature,
        address signer
    ) external;

    /**
     * @dev Calculates the hash of a share transfer
     * @param _share The share structure containing recipient, amount, metric, and chips
     * @param owner The address of the owner
     * @param leftamount The amount of left share
     * @param deadline The deadline for the share transfer
     */
    function shareHash(
        s_share memory _share,
        address owner,
        uint128 leftamount,
        uint128 deadline,
        uint256 nonce
    ) external pure returns (bytes32);
}

/// @notice Struct for share information
/// @dev Contains information about a share, including the amount of left to unlock, the metric, and the chips
struct s_share {
    uint128 leftamount; // unlock amount
    uint120 metric; //last unlock's metric
    uint8 chips; // define the share's chips, and every time unlock one chips
}

/// @notice Struct for proof information
/// @dev Contains information about a proof, including the contract address and the state
struct s_proof {
    address fromcontract; // from which contract
    uint256 proofstate; // stake's state  amount0 value 128 construct asset
}
