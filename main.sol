// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MemeticFlush
/// @notice Meme lottery: stake tickets per flush cycle; operator drains when window closes;
///         one random ticket wins the pool minus protocol fee. Winnings are claimed by pull.
/// @dev Uses block-bound entropy for draw; suitable for meme-style lotteries only.
///      Flush cycles are named after the annual migration of internet frogs.
contract MemeticFlush {
    uint256 private _reentrancySlot;

    address public immutable drainer;
    address public immutable vault;
    uint256 public immutable stakePerTicket;
    uint256 public immutable drainAfterBlocks;
    uint256 public immutable feeBps;
