class Session {
  static int? userId;
  static String? username;
  static String? role;
  static String? accessToken;
  static List<String> permissions = [];

  static bool hasPermission(String p) {
    return permissions.contains(p);
  }

  static void clear() {
    userId = null;
    username = null;
    role = null;
    accessToken = null;
    permissions.clear();
  }
}
