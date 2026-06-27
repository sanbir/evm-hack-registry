// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract Moneymon is ERC20, ERC20Burnable, ERC20Pausable, Ownable {

    uint256 public constant INITIAL_MINT = 500_000 ether;      // 500,000 tokens (unlocked)
    uint256 public constant MAX_SUPPLY = 1_000_000 ether;      // 1,000,000 total supply
    uint256 public constant LOCKED_SUPPLY = 500_000 ether;     // 500,000 tokens (locked)
    uint256 public constant LOCK_PERIOD = 90 days;             // 3 months lock
    uint256 public constant MONTHLY_RELEASE = 25_000 ether;    // 5% of locked = 25,000 tokens/month
    uint256 public constant RELEASE_INTERVAL = 30 days;        // Monthly interval

    uint256 public immutable DEPLOYMENT_TIME;
    uint256 public lastReleaseTime;
    uint256 public totalReleased;

    event TokensReleased(address indexed to, uint256 amount, uint256 timestamp);

    modifier withinMaxSupply(uint256 _amount) {
        require(totalSupply() + _amount <= MAX_SUPPLY, "Exceeds max supply");
        _;
    }

    modifier afterLockPeriod() {
        require(block.timestamp >= DEPLOYMENT_TIME + LOCK_PERIOD, "Locked supply still locked");
        _;
    }

    constructor(address initialOwner)
        ERC20("Moneymon", "MON")
        Ownable(initialOwner)
    {
        DEPLOYMENT_TIME = block.timestamp;
        lastReleaseTime = 0;
        totalReleased = 0;
        
        // Mint initial unlocked supply directly (bypass lock check)
        _mint(initialOwner, INITIAL_MINT);
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    /**
     * @dev Release locked tokens according to vesting schedule
     * - Can only be called after 90-day lock period
     * - Releases 25,000 tokens per month (5% of locked supply)
     * - Maximum 20 releases (500,000 tokens total)
     */
    function releaseLockedTokens(address to) public onlyOwner afterLockPeriod withinMaxSupply(MONTHLY_RELEASE) {
        require(totalReleased < LOCKED_SUPPLY, "All locked tokens released");
        
        // Check if enough time has passed since last release
        if (lastReleaseTime != 0) {
            require(
                block.timestamp >= lastReleaseTime + RELEASE_INTERVAL,
                "Release interval not elapsed"
            );
        }

        uint256 releaseAmount = MONTHLY_RELEASE;

        lastReleaseTime = block.timestamp;
        totalReleased += releaseAmount;

        _mint(to, releaseAmount);
        
        emit TokensReleased(to, releaseAmount, block.timestamp);
    }

    /**
     * @dev Returns remaining locked tokens to be released
     */
    function getRemainingLocked() public view returns (uint256) {
        return LOCKED_SUPPLY - totalReleased;
    }

    /**
     * @dev Returns time until next release is available
     */
    function getTimeUntilNextRelease() public view returns (uint256) {
        if (block.timestamp < DEPLOYMENT_TIME + LOCK_PERIOD) {
            return (DEPLOYMENT_TIME + LOCK_PERIOD) - block.timestamp;
        }
        
        if (lastReleaseTime == 0) {
            return 0; // First release available
        }
        
        uint256 nextReleaseTime = lastReleaseTime + RELEASE_INTERVAL;
        if (block.timestamp >= nextReleaseTime) {
            return 0; // Release available now
        }
        
        return nextReleaseTime - block.timestamp;
    }

    /**
     * @dev BEP-20 compatibility - returns owner address
     */
    function getOwner() external view returns (address) {
        return owner();
    }

    // Required overrides
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        super._update(from, to, value);
    }
}