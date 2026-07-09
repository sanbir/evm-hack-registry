// SPDX-License-Identifier: MIT

pragma solidity ^0.8.2;

interface IXNFT {

    function pledge(address collection, uint256 tokenId, uint256 nftType) external;
    function pledge721(address _collection, uint256 _tokenId) external;
    function pledge1155(address _collection, uint256 _tokenId) external;
    function getOrderDetail(uint256 orderId) external view returns(address collection, uint256 tokenId, address pledger);
    function isOrderLiquidated(uint256 orderId) external view returns(bool);
    function withdrawNFT(uint256 orderId) external;

    // Note: pledgeAndBorrow exists on the XNFT implementation (but not declared here) and is the entrypoint used in exploit.
    // It combines pledge + unvalidated xToken.borrow(0) allowing creation of Orders without debt.


    // onlyController
    function notifyOrderLiquidated(address xToken, uint256 orderId, address liquidator, uint256 liquidatedPrice) external;
    function notifyRepayBorrow(uint256 orderId) external;

}