"""
@title YFI Reward Pool
@author Curve Finance, Yearn Finance
@license MIT
"""
from vyper.interfaces import ERC20

interface VotingYFI:
    def user_point_epoch(addr: address) -> uint256: view
    def epoch() -> uint256: view
    def user_point_history(addr: address, loc: uint256) -> Point: view
    def point_history(loc: uint256) -> Point: view
    def checkpoint(): nonpayable
    def token() -> ERC20: view
    def modify_lock(amount: uint256, unlock_time: uint256, user: address) -> LockedBalance: nonpayable

event Initialized:
    veyfi: VotingYFI
    start_time: uint256

event CheckpointToken:
    time: uint256
    tokens: uint256

event Claimed:
    recipient: indexed(address)
    amount: uint256
    claim_epoch: uint256
    max_epoch: uint256

event AllowedToRelock:
    user: indexed(address)
    relocker: indexed(address)
    allowed: bool

struct Point:
    bias: int128
    slope: int128  # - dweight / dt
    ts: uint256
    blk: uint256  # block

struct LockedBalance:
    amount: uint256
    end: uint256


WEEK: constant(uint256) = 7 * 86400
TOKEN_CHECKPOINT_DEADLINE: constant(uint256) = 86400

YFI: immutable(ERC20)
VEYFI: immutable(VotingYFI)

start_time: public(uint256)
time_cursor: public(uint256)
time_cursor_of: public(HashMap[address, uint256])
user_epoch_of: public(HashMap[address, uint256])
allowed_to_relock: public(HashMap[address, HashMap[address, bool]])  # user -> relocker -> allowed

last_token_time: public(uint256)
tokens_per_week: public(HashMap[uint256, uint256])

total_received: public(uint256)
token_last_balance: public(uint256)
ve_supply: public(HashMap[uint256, uint256])


@external
def __init__(veyfi: VotingYFI, start_time: uint256):
    """
    @notice Contract constructor
    @param veyfi VotingYFI contract address
    @param start_time Epoch time for fee distribution to start
    """
    t: uint256 = start_time / WEEK * WEEK
    self.start_time = t
    self.last_token_time = t
    self.time_cursor = t
    VEYFI = veyfi
    YFI = VEYFI.token()

    log Initialized(veyfi, start_time)


@internal
def _checkpoint_token():
    token_balance: uint256 = YFI.balanceOf(self)
    to_distribute: uint256 = token_balance - self.token_last_balance
    self.token_last_balance = token_balance

    t: uint256 = self.last_token_time
    since_last: uint256 = block.timestamp - t
    self.last_token_time = block.timestamp
    this_week: uint256 = t / WEEK * WEEK
    next_week: uint256 = 0

    for i in range(20):
        next_week = this_week + WEEK
        if block.timestamp < next_week:
            if since_last == 0 and block.timestamp == t:
                self.tokens_per_week[this_week] += to_distribute
            else:
                self.tokens_per_week[this_week] += to_distribute * (block.timestamp - t) / since_last
            break
        else:
            if since_last == 0 and next_week == t:
                self.tokens_per_week[this_week] += to_distribute
            else:
                self.tokens_per_week[this_week] += to_distribute * (next_week - t) / since_last
        t = next_week
        this_week = next_week

    log CheckpointToken(block.timestamp, to_distribute)


@external
def checkpoint_token():
    """
    @notice Update the token checkpoint
    @dev Calculates the total number of tokens to be distributed in a given week.
         During setup for the initial distribution this function is only callable
         by the contract owner. Beyond initial distro, it can be enabled for anyone
         to call.
    """
    assert block.timestamp > self.last_token_time + TOKEN_CHECKPOINT_DEADLINE
    self._checkpoint_token()


@internal
def _find_timestamp_epoch(ve: address, _timestamp: uint256) -> uint256:
    _min: uint256 = 0
    _max: uint256 = VEYFI.epoch()
    for i in range(128):
        if _min >= _max:
            break
        _mid: uint256 = (_min + _max + 2) / 2
        pt: Point = VEYFI.point_history(_mid)
        if pt.ts <= _timestamp:
            _min = _mid
        else:
            _max = _mid - 1
    return _min


@view
@internal
def _find_timestamp_user_epoch(ve: address, user: address, _timestamp: uint256, max_user_epoch: uint256) -> uint256:
    _min: uint256 = 0
    _max: uint256 = max_user_epoch
    for i in range(128):
        if _min >= _max:
            break
        _mid: uint256 = (_min + _max + 2) / 2
        pt: Point = VEYFI.user_point_history(user, _mid)
        if pt.ts <= _timestamp:
            _min = _mid
        else:
            _max = _mid - 1
    return _min


@view
@external
def ve_for_at(_user: address, _timestamp: uint256) -> uint256:
    """
    @notice Get the veYFI balance for `_user` at `_timestamp`
    @param _user Address to query balance for
    @param _timestamp Epoch time
    @return uint256 veYFI balance
    """
    max_user_epoch: uint256 = VEYFI.user_point_epoch(_user)
    epoch: uint256 = self._find_timestamp_user_epoch(VEYFI.address, _user, _timestamp, max_user_epoch)
    pt: Point = VEYFI.user_point_history(_user, epoch)
    zero: int128 = 0
    return convert(max(pt.bias - pt.slope * convert(_timestamp - pt.ts, int128), zero), uint256)


@internal
def _checkpoint_total_supply():
    t: uint256 = self.time_cursor
    rounded_timestamp: uint256 = block.timestamp / WEEK * WEEK
    VEYFI.checkpoint()

    for i in range(20):
        if t > rounded_timestamp:
            break
        else:
            epoch: uint256 = self._find_timestamp_epoch(VEYFI.address, t)
            pt: Point = VEYFI.point_history(epoch)
            dt: int128 = 0
            if t > pt.ts:
                # If the point is at 0 epoch, it can actually be earlier than the first deposit
                # Then make dt 0
                dt = convert(t - pt.ts, int128)
            zero: int128 = 0
            self.ve_supply[t] = convert(max(pt.bias - pt.slope * dt, zero), uint256)
        t += WEEK

    self.time_cursor = t


@external
def checkpoint_total_supply():
    """
    @notice Update the veYFI total supply checkpoint
    @dev The checkpoint is also updated by the first claimant each
         new epoch week. This function may be called independently
         of a claim, to reduce claiming gas costs.
    """
    self._checkpoint_total_supply()


@internal
def _claim(addr: address, last_token_time: uint256) -> uint256:
    # Minimal user_epoch is 0 (if user had no point)
    user_epoch: uint256 = 0
    to_distribute: uint256 = 0

    max_user_epoch: uint256 = VEYFI.user_point_epoch(addr)
    _start_time: uint256 = self.start_time

    if max_user_epoch == 0:
        # No lock = no fees
        return 0

    week_cursor: uint256 = self.time_cursor_of[addr]
    if week_cursor == 0:
        # Need to do the initial binary search
        user_epoch = self._find_timestamp_user_epoch(VEYFI.address, addr, _start_time, max_user_epoch)
    else:
        user_epoch = self.user_epoch_of[addr]

    if user_epoch == 0:
        user_epoch = 1

    user_point: Point = VEYFI.user_point_history(addr, user_epoch)

    if week_cursor == 0:
        week_cursor = (user_point.ts + WEEK - 1) / WEEK * WEEK

    if week_cursor >= last_token_time:
        return 0

    if week_cursor < _start_time:
        week_cursor = _start_time
    old_user_point: Point = empty(Point)

    # Iterate over weeks
    for i in range(50):
        if week_cursor >= last_token_time:
            break

        if week_cursor >= user_point.ts and user_epoch <= max_user_epoch:
            user_epoch += 1
            old_user_point = user_point
            if user_epoch > max_user_epoch:
                user_point = empty(Point)
            else:
                user_point = VEYFI.user_point_history(addr, user_epoch)

        else:
            # Calc
            # + i * 2 is for rounding errors
            dt: int128 = convert(week_cursor - old_user_point.ts, int128)
            zero: int128 = 0
            balance_of: uint256 = convert(max(old_user_point.bias - dt * old_user_point.slope, zero), uint256)
            if balance_of == 0 and user_epoch > max_user_epoch:
                break
            if balance_of > 0:
                to_distribute += balance_of * self.tokens_per_week[week_cursor] / self.ve_supply[week_cursor]

            week_cursor += WEEK

    user_epoch = min(max_user_epoch, user_epoch - 1)
    self.user_epoch_of[addr] = user_epoch
    self.time_cursor_of[addr] = week_cursor

    log Claimed(addr, to_distribute, user_epoch, max_user_epoch)

    return to_distribute


@external
@nonreentrant('lock')
def claim(user: address = msg.sender, relock: bool = False) -> uint256:
    """
    @notice Claim fees for a user
    @dev 
        Each call to claim looks at a maximum of 50 user veYFI points.
        For accounts with many veYFI related actions, this function
        may need to be called more than once to claim all available
        fees. In the `Claimed` event that fires, if `claim_epoch` is
        less than `max_epoch`, the account may claim again.
    @param user account to claim the fees for
    @param relock whether to increase the lock from the claimed fees
    @return uint256 amount of the claimed fees
    """
    if block.timestamp >= self.time_cursor:
        self._checkpoint_total_supply()

    last_token_time: uint256 = self.last_token_time

    if block.timestamp > last_token_time + TOKEN_CHECKPOINT_DEADLINE:
        self._checkpoint_token()
        last_token_time = block.timestamp

    last_token_time = last_token_time / WEEK * WEEK

    amount: uint256 = self._claim(user, last_token_time)
    if amount != 0:
        # you can only relock for yourself
        if relock and (msg.sender == user or self.allowed_to_relock[user][msg.sender]):
            YFI.approve(VEYFI.address, amount)
            VEYFI.modify_lock(amount, 0, user)
        else:
            assert YFI.transfer(user, amount)
        self.token_last_balance -= amount

    return amount


@external
def burn(amount: uint256 = MAX_UINT256) -> bool:
    """
    @notice Receive YFI into the contract and trigger a token checkpoint
    @param amount Amount of tokens to pull [default: allowance]
    @return bool success
    """
    _amount: uint256 = amount
    if _amount == MAX_UINT256:
        _amount = YFI.allowance(msg.sender, self)
    if _amount > 0:
        YFI.transferFrom(msg.sender, self, _amount)
        if block.timestamp > self.last_token_time + TOKEN_CHECKPOINT_DEADLINE:
            self._checkpoint_token()

    return True


@external
def toggle_allowed_to_relock(user: address) -> bool:
    """
    @notice Control whether a user or a contract can relock rewards on your behalf
    @param user account to delegate the right to relock
    """
    old_value: bool = self.allowed_to_relock[msg.sender][user]
    self.allowed_to_relock[msg.sender][user] = not old_value
    log AllowedToRelock(msg.sender, user, not old_value)
    return True


@view
@external
def token() -> ERC20:
    return YFI


@view
@external
def veyfi() -> VotingYFI:
    return VEYFI
