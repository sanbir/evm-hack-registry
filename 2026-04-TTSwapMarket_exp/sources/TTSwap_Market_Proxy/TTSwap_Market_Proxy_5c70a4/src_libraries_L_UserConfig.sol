// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/// @title User Configuration Library
/// @notice Library for managing user permissions and roles within the TTSwap system.
/// @dev Uses bitwise operations on a `uint256` to store boolean flags and addresses efficiently.
/// 
/// Permission Layout (Bit Index):
/// - 255: DAO Admin
/// - 254: Token Admin
/// - 253: Token Manager
/// - 252: Market Admin
/// - 251: Market Manager
/// - 250: Can Call Mint TTS (Contract Role)
/// - 249: Stake Admin
/// - 248: Stake Manager
/// - 160: Ban Status
/// - [0-159]: Referral Address (160 bits)
library L_UserConfigLibrary {
    /// @notice Checks if the user has DAO Admin privileges.
    /// @param config The user's configuration value.
    /// @return a True if DAO Admin, false otherwise.
    function isDAOAdmin(uint256 config) internal pure returns(bool a){
        return (config&uint256(2**255))>0;
    }

    /// @notice Sets or unsets DAO Admin privileges.
    /// @param config The current configuration value.
    /// @param a The new boolean status.
    /// @return e The updated configuration value.
    function setDAOAdmin(uint256 config,bool a)internal pure  returns(uint256 e){
        return (config&(~(uint256(2**255))))|(a?uint256(2**255):0);
    }

    /// @notice Checks if the user has Token Admin privileges.
    function isTokenAdmin(uint256 config) internal pure returns(bool a){
        return (config&uint256(2**254))>0;
    }

    /// @notice Sets or unsets Token Admin privileges.
    function setTokenAdmin(uint256 config,bool a)internal pure  returns(uint256 e){
        return config&~(uint256(2**254))|(a?uint256(2**254):0);
    }

    /// @notice Checks if the user has Token Manager privileges.
    function isTokenManager(uint256 config) internal pure returns(bool a){
        return (config&uint256(2**253))>0;
    }

    /// @notice Sets or unsets Token Manager privileges.
    function setTokenManager(uint256 config,bool a)internal pure  returns(uint256 e){
        return config&~(uint256(2**253))|(a?uint256(2**253):0);
    }

    /// @notice Checks if the user has Market Admin privileges.
    function isMarketAdmin(uint256 config)internal pure returns(bool a){
        return (config&uint256(2**252))>0;
    }

    /// @notice Sets or unsets Market Admin privileges.
    function setMarketAdmin(uint256 config,bool a)internal pure  returns(uint256 e){
        return config&~(uint256(2**252))|(a?uint256(2**252):0);
    }

    /// @notice Checks if the user has Market Manager privileges.
    function isMarketManager(uint256 config)internal pure returns(bool a){
        return (config&uint256(2**251))>0;
    }

    /// @notice Sets or unsets Market Manager privileges.
    function setMarketManager(uint256 config,bool a)internal pure  returns(uint256 e){
        return config&~(uint256(2**251))|(a?uint256(2**251):0);
    }

    /// @notice Checks if the user (contract) is authorized to call mint functions.
    function isCallMintTTS(uint256 config)internal pure returns(bool a){
        return (config&uint256(2**250))>0;
    }

    /// @notice Sets or unsets mint calling authorization.
    function setCallMintTTS(uint256 config,bool a)internal pure returns(uint256 e){
        return config&~(uint256(2**250))|(a?uint256(2**250):0);
    }

    /// @notice Checks if the user has Stake Admin privileges.
    function isStakeAdmin(uint256 config)internal pure returns(bool a){
        return (config&uint256(2**249))>0;
    }

    /// @notice Sets or unsets Stake Admin privileges.
    function setStakeAdmin(uint256 config,bool a)internal pure returns(uint256 e){
        return config&~(uint256(2**249))|(a?uint256(2**249):0);
    }

    /// @notice Checks if the user has Stake Manager privileges.
    function isStakeManager(uint256 config)internal pure returns(bool a){
        return (config&uint256(2**248))>0;
    }

    /// @notice Sets or unsets Stake Manager privileges.
    function setStakeManager(uint256 config,bool a)internal pure returns(uint256 e){
        return config&~(uint256(2**248))|(a?uint256(2**248):0);
    }

    /// @notice Checks if the user is banned.
    function isBan(uint256 config)internal pure returns(bool a){
        return (config&uint256(2**160))>0;
    }

    /// @notice Sets or unsets the ban status.
    function setBan(uint256 config,bool a)internal pure returns(uint256 e){
        return config&~(uint256(2**160))|(a?uint256(2**160):0);
    }

    /// @notice Retrieves the referral address associated with the user.
    /// @dev Returns the lower 160 bits cast as an address.
    function referral(uint256 config)internal pure returns(address a){
        return address(uint160(config));
    }

    /// @notice Sets the referral address for the user.
    /// @dev Clears the lower 160 bits and ORs them with the new address.
    function setReferral(uint256 config,address a)internal pure returns(uint256 e){
        return (config&~(uint256(2**160)-1))|uint256(uint160(a));
    }

}
