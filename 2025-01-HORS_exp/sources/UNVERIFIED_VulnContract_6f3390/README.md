Address: 0x6f3390c6C200e9bE81b32110CE191a293dc0eaba (BSC)
Status: UNVERIFIED on BscScan (no source available)
Selectors present in bytecode: 0x7494d122, 0xc1459c03, 0xf78283c7
Exploited selector: 0xf78283c7(address token, address recipient, address lpToken)
Behavior reconstructed from on-chain trace (see ../../output.txt):
  - reads token.balanceOf(self); transfers it to 0xBE0eB53F... (was 0 for HORS); approves recipient for it
  - reads lpToken.balanceOf(self) = WBNB/HORS Cake-LP balance; approves recipient for FULL LP balance
  - calls recipient.addLiquidity(lpToken, token, lpBal, 0, lpBal, 0, self, deadline) -- an UNTRUSTED external callback into the caller-supplied recipient
  - No access control / no caller validation / recipient is fully attacker-controlled
  - Inside the callback the attacker simply transferFrom(self -> attacker, lpBal) using the approval just granted, draining all LP tokens.
