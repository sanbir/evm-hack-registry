//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

/*
 * ########################
 * # NUMERIC CONSTANTS #
 * ########################
 */

// Basis points constants
uint32 constant BPS_DIVIDER = 1_000_000; // 100%
uint32 constant MAX_FEE_RATE_BPS = 10_000; // 1%
uint32 constant DEFAULT_FEE_RATE_BPS = 137; // 0.0137%

// Scaling and decimal constants
uint256 constant INITIAL_SHARES_SUPPLY = 1e18;
uint8 constant VAULT_DECIMALS = 18;

// Time constants
uint64 constant ONE_WEEK = 604_800;
uint64 constant ONE_DAY = 86_400;

/*
 * ########################
 * # ADDRESS CONSTANTS #
 * ########################
 */

// Core protocol addresses
address constant ADDRESS_REGISTRY_CONTRACT =
    0x0594cb5ca47eFE1Ff25C7B8B43E221683B4Db34c;

// Token addresses
address constant ADDRESS_SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

// External service addresses
address constant ADDRESS_AUGUSTUS_REGISTRY =
    0xa68bEA62Dc4034A689AA0F58A76681433caCa663;
address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

/*
 * ########################
 * # STRING CONSTANTS #
 * ########################
 */

string constant VAULT_NAME = "usUSDS++";
string constant VAULT_SYMBOL = "usUSDS++";

/*
 * ########################
 * # CONTRACT IDENTIFIERS #
 * ########################
 */

bytes32 constant CONTRACT_REGISTRY_ACCESS =
    keccak256("CONTRACT_REGISTRY_ACCESS");
bytes32 constant CONTRACT_YIELD_TREASURY = keccak256("CONTRACT_YIELD_TREASURY");
bytes32 constant CONTRACT_USD0 = keccak256("CONTRACT_USD0");
bytes32 constant CONTRACT_USD0PP = keccak256("CONTRACT_USD0PP");

/*
 * ########################
 * # ROLE IDENTIFIERS #
 * ########################
 */

// Vault roles
bytes32 constant VAULT_PAUSER_ROLE = keccak256("VAULT_PAUSER_ROLE");
bytes32 constant VAULT_UNPAUSER_ROLE = keccak256("VAULT_UNPAUSER_ROLE");
bytes32 constant VAULT_SET_ROUTER_ROLE = keccak256("VAULT_SET_ROUTER_ROLE");
bytes32 constant VAULT_SET_FEE_ROLE = keccak256("VAULT_SET_FEE_ROLE");
bytes32 constant VAULT_HARVESTER_ROLE = keccak256("VAULT_HARVESTER_ROLE");

// Router roles
bytes32 constant ROUTER_RESCUER_ROLE = keccak256("ROUTER_RESCUER_ROLE");
bytes32 constant ROUTER_PAUSER_ROLE = keccak256("ROUTER_PAUSER_ROLE");
bytes32 constant ROUTER_UNPAUSER_ROLE = keccak256("ROUTER_UNPAUSER_ROLE");

// USD0PP roles
bytes32 constant UNWRAP_CAP_ALLOCATOR_ROLE =
    keccak256("UNWRAP_CAP_ALLOCATOR_ROLE");
bytes32 constant USD0PP_CAPPED_UNWRAP_ROLE =
    keccak256("USD0PP_CAPPED_UNWRAP_ROLE");
