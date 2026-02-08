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

    modifier noReentrancy() {
        if (_reentrancySlot != 0) revert ReentrancyDetected();
        _reentrancySlot = 1;
        _;
        _reentrancySlot = 0;
    }

    modifier onlyDrainer() {
        if (msg.sender != drainer) revert CallerNotDrainer();
        _;
    }

    constructor() {
        drainer = msg.sender;
        vault = address(0x3D7fA2b9C1e4E6d8F0a2B4c6D8e0F2A4b6C8d0E);
        stakePerTicket = 0.0077 ether;
        drainAfterBlocks = 4320;
        feeBps = 350;
        capTicketsPerStake = 88;
        cooldownBlocks = 256;
        genesisBlock = block.number;
        currentCycle = 1;
        cycleStartBlock = block.number;
        cycleStartBlockById[1] = block.number;
        emit NewCycleOpened(1, block.number);
    }

    /// @dev Stake ETH to receive lottery tickets in the current cycle.
    function stakeTickets(uint256 numTickets) external payable noReentrancy {
        if (numTickets == 0 || numTickets > capTicketsPerStake) revert InvalidTicketCount();
        uint256 requiredWei = numTickets * stakePerTicket;
        if (msg.value != requiredWei) revert StakeWeiMismatch();
        if (cycleDrained[currentCycle]) revert CycleAlreadyDrained();

        if (cycleTicketsOf[currentCycle][msg.sender] == 0) {
            _cycleEntrants[currentCycle].push(msg.sender);
        }
        cycleTicketsOf[currentCycle][msg.sender] += numTickets;
        cycleTotalTickets[currentCycle] += numTickets;
        cyclePoolWei[currentCycle] += msg.value;

        emit TicketStaked(msg.sender, currentCycle, numTickets, msg.value);
    }

    /// @dev Operator drains the current cycle: pick winner, send fee to vault, mark cycle resolved.
    function drainCycle() external onlyDrainer noReentrancy {
        if (block.number < cycleStartBlock + drainAfterBlocks) revert DrainWindowNotReached();
        if (cycleTotalTickets[currentCycle] == 0) revert CycleHasNoTickets();
        if (cycleDrained[currentCycle]) revert CycleAlreadyDrained();

        uint256 pool = cyclePoolWei[currentCycle];
        uint256 fee = (pool * feeBps) / 10000;

        uint256 seed = uint256(
            keccak256(
                abi.encodePacked(
                    blockhash(block.number - 1),
                    block.prevrandao,
                    block.timestamp,
                    currentCycle,
                    cycleTotalTickets[currentCycle]
                )
            )
        );
        uint256 winnerTicketIndex = seed % cycleTotalTickets[currentCycle];
        address winner = _resolveWinnerByTicketIndex(currentCycle, winnerTicketIndex);

        cycleDrained[currentCycle] = true;
        cycleWinner[currentCycle] = winner;
        cycleFeeWei[currentCycle] = fee;
        cycleDrainBlock[currentCycle] = block.number;

        if (fee > 0) {
            (bool sent,) = vault.call{value: fee}("");
            require(sent, "Fee transfer failed");
        }

        emit CycleDrained(currentCycle, winner, pool, fee, block.number);
    }

    /// @dev Winner claims their winnings for a given cycle (pull pattern).
    function pullWinnings(uint256 cycleId) external noReentrancy {
        if (!cycleDrained[cycleId]) revert CycleNotDrained();
        if (cycleWinner[cycleId] != msg.sender) revert CallerNotWinner();
        if (cycleWinningsClaimed[cycleId][msg.sender]) revert WinningsAlreadyPulled();

        uint256 pool = cyclePoolWei[cycleId];
        uint256 fee = cycleFeeWei[cycleId];
        uint256 amount = pool - fee;

        cycleWinningsClaimed[cycleId][msg.sender] = true;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "Transfer failed");

        emit WinningsPulled(cycleId, msg.sender, amount);
    }

    /// @dev Operator starts a new cycle after cooldown.
    function openNewCycle() external onlyDrainer {
        if (!cycleDrained[currentCycle] && cycleTotalTickets[currentCycle] > 0) {
            revert DrainWindowNotReached();
        }
        if (block.number < cycleStartBlock + cooldownBlocks) revert NewCycleTooSoon();

        currentCycle++;
        cycleStartBlock = block.number;
        cycleStartBlockById[currentCycle] = block.number;
        emit NewCycleOpened(currentCycle, block.number);
    }

    function _resolveWinnerByTicketIndex(
        uint256 cycle,
        uint256 ticketIndex
    ) internal view returns (address) {
        address[] memory entrants = _cycleEntrants[cycle];
        uint256 cursor;
        for (uint256 i; i < entrants.length; ) {
            uint256 count = cycleTicketsOf[cycle][entrants[i]];
            if (ticketIndex < cursor + count) return entrants[i];
            cursor += count;
            unchecked { i++; }
        }
        return entrants[entrants.length - 1];
    }

    // ---------- views ----------
