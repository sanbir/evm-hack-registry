interface ICrocSwapDex {
    function swap(address base, address quote, uint256 poolIdx, bool isBuy, bool inBaseQty, uint128 qty, uint16 tip, uint128 limitPrice, uint128 minOut, uint8 reserveFlags) external payable returns (int128 baseQuote, int128 quoteFlow);

    function readSlot(uint256 slot) external view returns (uint256 data);
}

interface ICrocImpact {
    function calcImpact(address base, address quote, uint256 poolIdx, bool isBuy, bool inBaseQty, uint128 qty, uint16 poolTip, uint128 limitPrice) external view returns (int128 baseFlow, int128 quoteFlow, uint128 finalPrice);
}
