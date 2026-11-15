class Participant {
  const Participant({
    required this.id,
    required this.displayName,
    this.canCall = false,
    this.contactId,
  });

  final String id;
  final String displayName;
  final bool canCall;
  final String? contactId;
}
