// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

interface IP2EERC1155 {

    function create(
        uint256 _maxSupply,
        uint256 _initialSupply,
        uint256 _type,
        bytes calldata _data
    ) external returns (uint256 tokenId);

    function createBatch(
        uint256 _maxSupply,
        uint256 _initialSupply,
        uint256[] calldata _types,
        uint256[] calldata _values,
        bytes calldata _data
    ) external returns (uint256[] calldata tokenIds);

    function createBatchDefault(uint256[] calldata _types, uint256[] calldata _values) external returns (uint256[] calldata tokenIds);

    function mint(address to, uint256 _id, uint256 _quantity, bytes calldata _data) external;

    function burn(address _account, uint256 _id, uint256 _amount) external;

    function burnBatch(address account, uint256[] calldata ids, uint256[] calldata amounts) external;

    function balanceOf(address account, uint256 id) external view returns (uint256);

    function totalBalance(address account, uint256[] calldata ids) external view returns (uint256, uint256[] calldata);

    function balanceOfBatch(
        address[] calldata accounts,
        uint256[] calldata ids
    ) external view returns (uint256[] calldata);

    function disableTokenTransfer(uint _id) external;

    function enableTokenTransfer(uint _id) external;

}
