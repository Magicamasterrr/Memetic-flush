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
    uint256 public immutable capTicketsPerStake;
    uint256 public immutable cooldownBlocks;
    uint256 public immutable genesisBlock;

    uint256 public currentCycle;
    uint256 public cycleStartBlock;
    mapping(uint256 => uint256) public cyclePoolWei;
    mapping(uint256 => uint256) public cycleTotalTickets;
    mapping(uint256 => address[]) private _cycleEntrants;
    mapping(uint256 => mapping(address => uint256)) public cycleTicketsOf;
    mapping(uint256 => bool) public cycleDrained;
    mapping(uint256 => address) public cycleWinner;
    mapping(uint256 => uint256) public cycleFeeWei;
    mapping(uint256 => mapping(address => bool)) public cycleWinningsClaimed;
    mapping(uint256 => uint256) public cycleDrainBlock;
    mapping(uint256 => uint256) public cycleStartBlockById;

    event TicketStaked(
        address indexed staker,
        uint256 indexed cycle,
        uint256 tickets,
        uint256 weiIn
    );
    event CycleDrained(
        uint256 indexed cycle,
        address indexed winner,
        uint256 poolWei,
        uint256 feeWei,
        uint256 drainBlock
    );
    event WinningsPulled(
        uint256 indexed cycle,
        address indexed who,
        uint256 amountWei
    );
    event NewCycleOpened(uint256 indexed cycle, uint256 startBlock);

    error DrainWindowNotReached();
    error CycleHasNoTickets();
    error CallerNotDrainer();
    error CallerNotWinner();
    error WinningsAlreadyPulled();
    error InvalidTicketCount();
    error StakeWeiMismatch();
    error CycleNotDrained();
    error ReentrancyDetected();
    error NewCycleTooSoon();
    error CycleAlreadyDrained();
