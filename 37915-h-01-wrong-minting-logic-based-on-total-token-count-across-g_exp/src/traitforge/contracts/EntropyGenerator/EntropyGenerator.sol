// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import './IEntropyGenerator.sol';

// EntropyGenerator is a contract designed to generate pseudo-random values for use in other contracts
contract EntropyGenerator is IEntropyGenerator, Ownable, Pausable {
  uint256[770] private entropySlots; // Array to store entropy values
  uint256 private lastInitializedIndex = 0; // Indexes to keep track of the initialization and usage of entropy values
  uint256 private currentSlotIndex = 0;
  uint256 private currentNumberIndex = 0;
  uint256 private batchSize1 = 256;
  uint256 private batchSize2 = 512;
  // Constants to define the limits for slots and numbers within those slots
  uint256 private maxSlotIndex = 770;
  uint256 private maxNumberIndex = 13;
  uint256 public slotIndexSelectionPoint;
  uint256 public numberIndexSelectionPoint;

  address private allowedCaller;

  // Modifier to restrict certain functions to the allowed caller
  modifier onlyAllowedCaller() {
    require(msg.sender == allowedCaller, 'Caller is not allowed');
    _;
  }

  constructor(address _traitForgetNft) {
    allowedCaller = _traitForgetNft;
    initializeAlphaIndices();
  }

  // Function to update the allowed caller, restricted to the owner of the contract
  function setAllowedCaller(address _allowedCaller) external onlyOwner {
    allowedCaller = _allowedCaller;
    emit AllowedCallerUpdated(_allowedCaller); // Emit an event for this update.
  }

  // function to get the current allowed caller
  function getAllowedCaller() external view returns (address) {
    return allowedCaller;
  }

  // Functions to initalize entropy values inbatches to spread gas cost over multiple transcations
  function writeEntropyBatch1() public {
    require(lastInitializedIndex < batchSize1, 'Batch 1 already initialized.');

    uint256 endIndex = lastInitializedIndex + batchSize1; // calculate the end index for the batch
    unchecked {
      for (uint256 i = lastInitializedIndex; i < endIndex; i++) {
        uint256 pseudoRandomValue = uint256(
          keccak256(abi.encodePacked(block.number, i))
        ) % uint256(10) ** 78; // generate a  pseudo-random value using block number and index
        require(pseudoRandomValue != 999999, 'Invalid value, retry.');
        entropySlots[i] = pseudoRandomValue; // store the value in the slots array
      }
    }
    lastInitializedIndex = endIndex;
  }

  // second batch initialization
  function writeEntropyBatch2() public {
    require(
      lastInitializedIndex >= batchSize1 && lastInitializedIndex < batchSize2,
      'Batch 2 not ready or already initialized.'
    );

    uint256 endIndex = lastInitializedIndex + batchSize1;
    unchecked {
      for (uint256 i = lastInitializedIndex; i < endIndex; i++) {
        uint256 pseudoRandomValue = uint256(
          keccak256(abi.encodePacked(block.number, i))
        ) % uint256(10) ** 78;
        require(pseudoRandomValue != 999999, 'Invalid value, retry.');
        entropySlots[i] = pseudoRandomValue;
      }
    }
    lastInitializedIndex = endIndex;
  }

  // allows setting a specific entropy slot with a value
  function writeEntropyBatch3() public {
    require(
      lastInitializedIndex >= batchSize2 && lastInitializedIndex < maxSlotIndex,
      'Batch 3 not ready or already completed.'
    );
    unchecked {
      for (uint256 i = lastInitializedIndex; i < maxSlotIndex; i++) {
        uint256 pseudoRandomValue = uint256(
          keccak256(abi.encodePacked(block.number, i))
        ) % uint256(10) ** 78;
        entropySlots[i] = pseudoRandomValue;
      }
    }
    lastInitializedIndex = maxSlotIndex;
  }

  // function to retrieve the next entropy value, accessible only by the allowed caller
  function getNextEntropy() public onlyAllowedCaller returns (uint256) {
    require(currentSlotIndex <= maxSlotIndex, 'Max slot index reached.');
    uint256 entropy = getEntropy(currentSlotIndex, currentNumberIndex);

    if (currentNumberIndex >= maxNumberIndex - 1) {
      currentNumberIndex = 0;
      if (currentSlotIndex >= maxSlotIndex - 1) {
        currentSlotIndex = 0;
      } else {
        currentSlotIndex++;
      }
    } else {
      currentNumberIndex++;
    }

    // Emit the event with the retrieved entropy value
    emit EntropyRetrieved(entropy);

    return entropy;
  }

  // public function to expose entropy calculation for a given slot and number index
  function getPublicEntropy(
    uint256 slotIndex,
    uint256 numberIndex
  ) public view returns (uint256) {
    return getEntropy(slotIndex, numberIndex);
  }

  // function to get the last initialized index for debugging or informational puroposed
  function getLastInitializedIndex() public view returns (uint256) {
    return lastInitializedIndex;
  }

  // function to derive various parameters baed on entrtopy values, demonstrating potential cases
  function deriveTokenParameters(
    uint256 slotIndex,
    uint256 numberIndex
  )
    public
    view
    returns (
      uint256 nukeFactor,
      uint256 forgePotential,
      uint256 performanceFactor,
      bool isForger
    )
  {
    uint256 entropy = getEntropy(slotIndex, numberIndex);

    // example calcualtions using entropyto derive game-related parameters
    nukeFactor = entropy / 4000000;
    forgePotential = getFirstDigit(entropy);
    performanceFactor = entropy % 10;

    // exmaple logic to determine a boolean property based on entropy
    uint256 role = entropy % 3;
    isForger = role == 0;

    return (nukeFactor, forgePotential, performanceFactor, isForger); // return derived parammeters
  }

  // private function to calculate the entropy value based on slot and number index
  function getEntropy(
    uint256 slotIndex,
    uint256 numberIndex
  ) private view returns (uint256) {
    require(slotIndex <= maxSlotIndex, 'Slot index out of bounds.');

    if (
      slotIndex == slotIndexSelectionPoint &&
      numberIndex == numberIndexSelectionPoint
    ) {
      return 999999;
    }

    uint256 position = numberIndex * 6; // calculate the position for slicing the entropy value
    require(position <= 72, 'Position calculation error');

    uint256 slotValue = entropySlots[slotIndex]; // slice the required [art of the entropy value
    uint256 entropy = (slotValue / (10 ** (72 - position))) % 1000000; // adjust the entropy value based on the number of digits
    uint256 paddedEntropy = entropy * (10 ** (6 - numberOfDigits(entropy)));

    return paddedEntropy; // return the caculated entropy value
  }

  // Utility function te calcualte the number of digits in a number
  function numberOfDigits(uint256 number) private pure returns (uint256) {
    uint256 digits = 0;
    while (number != 0) {
      number /= 10;
      digits++;
    }
    return digits;
  }

  // utility to get he first digit of a number
  function getFirstDigit(uint256 number) private pure returns (uint256) {
    while (number >= 10) {
      number /= 10;
    }
    return number;
  }

  //select index points for 999999, triggered each gen-increment
  function initializeAlphaIndices() public whenNotPaused onlyOwner {
    uint256 hashValue = uint256(
      keccak256(abi.encodePacked(blockhash(block.number - 1), block.timestamp))
    );

    uint256 slotIndexSelection = (hashValue % 258) + 512;
    uint256 numberIndexSelection = hashValue % 13;

    slotIndexSelectionPoint = slotIndexSelection;
    numberIndexSelectionPoint = numberIndexSelection;
  }
}
