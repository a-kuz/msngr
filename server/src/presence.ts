/// A chat with more members than this builds no presence relations among
/// them: a roster of n makes n² of them, and a member list that large is
/// read, not watched.
///
/// Who may actually see whose presence is decided inside the source's own
/// object (`UserDO.visibleSubscribers`), where the tier, the named exceptions,
/// the blocks and the address book all live.
export const PRESENCE_GROUP_MAX = 100;
