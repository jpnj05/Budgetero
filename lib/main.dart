import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// ─── API Keys (injected via --dart-define at build/run time) ─────────────────
// Never hardcode keys here. See README.md for setup instructions.
const openAiKey = String.fromEnvironment('OPENAI_API_KEY', defaultValue: '');

// ─── Color Palette ───────────────────────────────────────
const kBg       = Color(0xFF0F1117);
const kSurface  = Color(0xFF1A1D26);
const kSurface2 = Color(0xFF222637);
const kAccent   = Color(0xFF6C63FF);
const kAccentLight = Color(0xFF9D97FF);
const kGreen    = Color(0xFF26C281);
const kRed      = Color(0xFFFF5252);
const kText     = Color(0xFFF0F0FF);
const kTextSub  = Color(0xFF8B8FA8);

// ─── Built-in Categories ─────────────────────────────────
const kBuiltinCats = [
  'Food','Shopping','Transport','Bills','Entertainment','Health','Other'
];

const categoryColors = {
  'Food':          Color(0xFFFF7043),
  'Shopping':      Color(0xFF7C4DFF),
  'Transport':     Color(0xFF00BCD4),
  'Bills':         Color(0xFFFFC107),
  'Entertainment': Color(0xFF26C281),
  'Health':        Color(0xFFFF5252),
  'Other':         Color(0xFF8B8FA8),
};

const kExtraColors = [
  Color(0xFFFF4081), Color(0xFF00E5FF), Color(0xFF76FF03),
  Color(0xFFFFD740), Color(0xFFE040FB), Color(0xFF40C4FF),
  Color(0xFFFF6D00), Color(0xFF69F0AE),
];

Color colorForCategory(String cat) {
  if (categoryColors.containsKey(cat)) return categoryColors[cat]!;
  final idx = cat.codeUnits.fold(0, (a, b) => a + b) % kExtraColors.length;
  return kExtraColors[idx];
}

IconData iconForCategory(String cat) {
  const map = {
    'Food':          Icons.restaurant_rounded,
    'Shopping':      Icons.shopping_bag_rounded,
    'Transport':     Icons.directions_car_rounded,
    'Bills':         Icons.receipt_long_rounded,
    'Entertainment': Icons.movie_rounded,
    'Health':        Icons.favorite_rounded,
    'Other':         Icons.category_rounded,
  };
  if (map.containsKey(cat)) return map[cat]!;
  final c = cat.toLowerCase();
  if (c.contains('apparel') || c.contains('cloth') || c.contains('shoe')) return Icons.checkroom_rounded;
  if (c.contains('pet')) return Icons.pets_rounded;
  if (c.contains('travel') || c.contains('hotel')) return Icons.flight_rounded;
  if (c.contains('school') || c.contains('edu')) return Icons.school_rounded;
  if (c.contains('sport') || c.contains('gym') || c.contains('fitness')) return Icons.fitness_center_rounded;
  if (c.contains('beauty') || c.contains('salon')) return Icons.face_retouching_natural_rounded;
  if (c.contains('tech') || c.contains('gadget') || c.contains('elect')) return Icons.devices_rounded;
  if (c.contains('gift')) return Icons.card_giftcard_rounded;
  if (c.contains('coffee') || c.contains('cafe')) return Icons.coffee_rounded;
  return Icons.label_rounded;
}

// ─── Global State ────────────────────────────────────────
List<Map<String, dynamic>> expenses    = [];
double budget                          = 0;
double customDailyLimit                = 0; // 0 = use auto-calculated
double customWeeklyLimit               = 0; // 0 = use auto-calculated
Map<String, String> learnedCategories = {};
Map<String, Color>  customCategoryColors = {};
ValueNotifier<int>  refreshNotifier   = ValueNotifier(0);

// ─── Notification Service ────────────────────────────────
class NotifService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios     = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );
    // Request Android 13+ permission
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
    _ready = true;
  }

  static Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!_ready) return;
    const androidDetails = AndroidNotificationDetails(
      'budgetero_alerts',
      'Budget Alerts',
      channelDescription: 'Smart spending alerts from Budgetero',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );
    const iosDetails = DarwinNotificationDetails();
    await _plugin.show(
      id,
      title,
      body,
      const NotificationDetails(android: androidDetails, iOS: iosDetails),
    );
  }

  // Trigger smart alerts based on current spending vs budget
  static Future<void> checkBudgetAlerts() async {
    if (budget <= 0 || expenses.isEmpty) return;
    final total   = expenses.fold(0.0, (s, e) => s + (e['amount'] as num));
    final pct     = total / budget;
    final prefs   = await SharedPreferences.getInstance();
    final lastPct = prefs.getDouble('last_alert_pct') ?? 0.0;

    if (pct >= 1.0 && lastPct < 1.0) {
      await show(
        id: 1,
        title: '⚠️ Over Budget!',
        body: 'You have exceeded your ₱${budget.toStringAsFixed(0)} budget. Time to slow down!',
      );
      await prefs.setDouble('last_alert_pct', pct);
    } else if (pct >= 0.9 && lastPct < 0.9) {
      await show(
        id: 2,
        title: '🚨 90% of Budget Used',
        body: 'Only ₱${(budget - total).toStringAsFixed(0)} left. Try to hold back on spending!',
      );
      await prefs.setDouble('last_alert_pct', pct);
    } else if (pct >= 0.7 && lastPct < 0.7) {
      await show(
        id: 3,
        title: '💛 70% of Budget Used',
        body: 'You have spent ₱${total.toStringAsFixed(0)} of your ₱${budget.toStringAsFixed(0)} budget.',
      );
      await prefs.setDouble('last_alert_pct', pct);
    }

    // Reset tracker when budget is cleared/reset
    if (pct < 0.7 && lastPct >= 0.7) {
      await prefs.setDouble('last_alert_pct', 0.0);
    }
  }

  // Daily reminder — call once on app open each new day
  static Future<void> maybeSendDailyReminder() async {
    if (budget <= 0) return;
    final prefs   = await SharedPreferences.getInstance();
    final today   = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final lastDay = prefs.getString('last_daily_notif') ?? '';
    if (lastDay == today) return;

    final total   = expenses.fold(0.0, (s, e) => s + (e['amount'] as num));
    final remain  = budget - total;
    final now     = DateTime.now();
    final daysLeft = DateUtils.getDaysInMonth(now.year, now.month) - now.day + 1;
    final dailyLimit = remain > 0 ? remain / daysLeft : 0.0;

    await show(
      id: 10,
      title: '📅 Daily Budget Tip',
      body: dailyLimit > 0
          ? 'Try to limit spending today to ₱${dailyLimit.toStringAsFixed(0)} to stay on track!'
          : 'You have no remaining budget this month. Avoid new expenses today!',
    );
    await prefs.setString('last_daily_notif', today);
  }
}

// ─── Persistence ─────────────────────────────────────────
Future<void> saveAll() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('expenses', jsonEncode(expenses));
  await prefs.setDouble('budget', budget);
  await prefs.setDouble('custom_daily_limit', customDailyLimit);
  await prefs.setDouble('custom_weekly_limit', customWeeklyLimit);
  await prefs.setString('learned', jsonEncode(learnedCategories));
}

Future<void> loadAll() async {
  final prefs = await SharedPreferences.getInstance();
  final exp = prefs.getString('expenses');
  if (exp != null) expenses = List<Map<String, dynamic>>.from(jsonDecode(exp));
  budget = prefs.getDouble('budget') ?? 0;
  customDailyLimit  = prefs.getDouble('custom_daily_limit')  ?? 0;
  customWeeklyLimit = prefs.getDouble('custom_weekly_limit') ?? 0;
  final learned = prefs.getString('learned');
  if (learned != null) learnedCategories = Map<String, String>.from(jsonDecode(learned));
}

// ─── Main ────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadAll();
  await NotifService.init();
  await NotifService.maybeSendDailyReminder();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kAccent, surface: kSurface),
        appBarTheme: const AppBarTheme(
          backgroundColor: kBg, elevation: 0,
          titleTextStyle: TextStyle(color: kText, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 0.3),
          iconTheme: IconThemeData(color: kText),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: kSurface, selectedItemColor: kAccent,
          unselectedItemColor: kTextSub, elevation: 0, type: BottomNavigationBarType.fixed,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true, fillColor: kSurface2,
          hintStyle: const TextStyle(color: kTextSub, fontSize: 14),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
      home: const Home(),
    );
  }
}

// ─── Navigation ──────────────────────────────────────────
class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  final screens = const [ChatScreen(), DashboardScreen()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: tab, children: screens),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: kSurface,
          border: Border(top: BorderSide(color: Color(0xFF2A2D3E), width: 1)),
        ),
        child: BottomNavigationBar(
          currentIndex: tab,
          onTap: (i) => setState(() => tab = i),
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.chat_bubble_outline_rounded), activeIcon: Icon(Icons.chat_bubble_rounded), label: "Chat"),
            BottomNavigationBarItem(icon: Icon(Icons.donut_large_outlined), activeIcon: Icon(Icons.donut_large_rounded), label: "Dashboard"),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// CHAT SCREEN
// ═══════════════════════════════════════════════════════════
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatState();
}

class _ChatState extends State<ChatScreen> {
  final controller = TextEditingController();
  final scrollCtrl = ScrollController();
  late stt.SpeechToText speech;
  bool isListening = false;
  bool isLoading   = false;
  List<Map<String, dynamic>> messages = [];

  @override
  void initState() {
    super.initState();
    speech = stt.SpeechToText();
    messages.add({
      "role": "bot",
      "text": "Hi! I'm **Budgetero** 💰\n\nJust tell me what you spent — I'll handle the rest!\n\n*\"Jollibee 120\"*  •  *\"45 bread Food\"*\n*\"Shoes 200 Apparel\"*  •  *\"Budget 5000\"*\n\nOr tap **Command Guide** below to see all commands.",
    });
  }

  // ─── Date Helpers ─────────────────────────────────────
  bool _isToday(DateTime d) {
    final n = DateTime.now();
    return d.year == n.year && d.month == n.month && d.day == n.day;
  }
  bool _isThisWeek(DateTime d) {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day).subtract(Duration(days: now.weekday - 1));
    return !d.isBefore(start);
  }
  bool _isThisMonth(DateTime d) {
    final n = DateTime.now();
    return d.year == n.year && d.month == n.month;
  }

  String _titleCase(String s) {
    if (s.isEmpty) return s;
    return s.split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1).toLowerCase()).join(' ');
  }

  // ════════════════════════════════════════════════════════
  // LOCAL FAST-PATH — handles budget & clear without API.
  // Returns true if the intent was handled locally.
  // ════════════════════════════════════════════════════════
  bool _tryLocalIntent(String input) {
    final lower = input.toLowerCase().trim();

    // ── SET BUDGET ───────────────────────────────────────
    // Handles: "Budget 1000", "my budget is 5000", "1000 budget",
    //          "set budget 3000", "set 2000 budget", "budget = 500"
    if (lower.contains('budget')) {
      final numMatch = RegExp(r'[\d,]+(?:\.\d+)?').firstMatch(lower);
      if (numMatch != null) {
        final amt = double.tryParse(numMatch.group(0)!.replaceAll(',', ''));
        if (amt != null && amt > 0) {
          budget = amt;
          saveAll();
          refreshNotifier.value++;
          _addBot(
            "✅ Budget set to **\u20B1${amt.toStringAsFixed(0)}**!\n\n"
            "I'll track your spending against this. Log your first expense anytime!",
          );
          return true;
        }
      }
    }

    // ── CLEAR ALL ────────────────────────────────────────
    if (RegExp(r'^(clear all|reset|reset everything|start over|burahin lahat)$')
        .hasMatch(lower)) {
      expenses.clear();
      budget = 0;
      learnedCategories.clear();
      saveAll();
      refreshNotifier.value++;
      _addBot("🧹 Everything cleared! Fresh start 👍");
      return true;
    }

    // ── CLEAR EXPENSES ONLY ──────────────────────────────
    if (RegExp(r'^(clear expenses|remove expenses|delete all expenses|burahin (lahat ng )?gastos)$')
        .hasMatch(lower)) {
      expenses.clear();
      learnedCategories.clear();
      saveAll();
      refreshNotifier.value++;
      _addBot(
        "🧹 All expenses cleared! Your budget of **\u20B1${budget.toStringAsFixed(0)}** is still set.",
      );
      return true;
    }

    return false;
  }

  // ─── Unified AI Brain ─────────────────────────────────
  Future<Map<String, dynamic>> askBrain(String userMessage) async {
    final now = DateTime.now();

    final allExpenses = expenses.map((e) {
      final d = DateTime.parse(e["date"]);
      return '${DateFormat("MMM d, EEE").format(d)}: \u20B1${e["amount"]} on ${e["item"]} [${e["category"]}]';
    }).join('\n');

    final todayTotal = expenses
        .where((e) => _isToday(DateTime.parse(e["date"])))
        .fold(0.0, (s, e) => s + (e["amount"] as num));
    final weekTotal = expenses
        .where((e) => _isThisWeek(DateTime.parse(e["date"])))
        .fold(0.0, (s, e) => s + (e["amount"] as num));
    final monthTotal = expenses
        .where((e) => _isThisMonth(DateTime.parse(e["date"])))
        .fold(0.0, (s, e) => s + (e["amount"] as num));
    final totalSpent = expenses.fold(0.0, (s, e) => s + (e["amount"] as num));
    final remaining  = budget > 0 ? budget - totalSpent : 0.0;

    final recentMsgs = messages.reversed
        .take(12)
        .toList()
        .reversed
        .map((m) => '${m["role"] == "user" ? "User" : "Budgetero"}: ${m["text"]}')
        .join('\n');

    final knownCats =
        [...kBuiltinCats, ...learnedCategories.values.toSet()].join(', ');

    // Build the prompt as a plain string (no special Unicode that trips Python)
    final prompt = '''
You are Budgetero, a smart and friendly AI budget assistant for Filipino users.
You understand natural language completely: casual phrasing, Taglish, abbreviations, any format.
CRITICAL LANGUAGE RULE: You MUST ALWAYS reply in English ONLY. Never use Filipino, Tagalog, or Taglish in your responses, even if the user writes in Filipino. Always respond 100% in English.

TODAY: ${DateFormat('EEEE, MMMM d, y').format(now)}

FINANCIAL DATA:
Budget: ${budget.toStringAsFixed(0)} ${budget == 0 ? "(not set)" : ""}
Total spent all time: ${totalSpent.toStringAsFixed(2)}
Spent today: ${todayTotal.toStringAsFixed(2)}
Spent this week: ${weekTotal.toStringAsFixed(2)}
Spent this month: ${monthTotal.toStringAsFixed(2)}
Remaining: ${remaining.toStringAsFixed(2)}
Known categories (open-ended, user can add any): $knownCats

All expenses (newest first):
${allExpenses.isEmpty ? "(none yet)" : allExpenses}

RECENT CONVERSATION:
$recentMsgs

NEW USER MESSAGE: $userMessage

YOUR JOB: Return a single JSON object (no markdown fences, no extra text):
{
  "action": "add_expense|set_budget|set_daily_limit|query|delete|delete_category|edit_expense|rename_category|clear_expenses|clear_all|chat",
  "reply": "warm natural response",
  "data": {}
}

ACTIONS:
- add_expense: data = {"expenses":[{"amount":number,"item":"Name","category":"Cat"},...]}
- set_budget: data = {"amount":number}
- query: data = {"mode":"list|total|insight|budget_check","category":"Name or null","time":"today|week|month|all"}
- delete: data = {"item":"name"}
- delete_category: data = {"category":"name"}
- edit_expense: data = {"match_item":"exact or partial item name to find","new_item":"new name or null","new_category":"new category or null","new_amount":number_or_null}
- rename_category: data = {"old_category":"exact category name","new_category":"new name"}
- set_daily_limit: data = {"daily":number_or_null,"weekly":number_or_null}
  Sets a custom daily and/or weekly spending limit shown on the dashboard.
  Pass null for a field to leave it unchanged. Pass 0 to reset it to auto-calculated.
  Examples: "set my daily limit to 200" -> daily:200, weekly:null
            "what if 1000 per week, update my dashboard" -> daily:null, weekly:1000
            "reset my daily limit" -> daily:0, weekly:null
            "set daily 150 and weekly 800" -> daily:150, weekly:800
- clear_expenses, clear_all, chat: data = {}

EDIT RULES:
- edit_expense: match_item is the CURRENT item name (or partial). Set only the fields that change; leave others null.
  Examples: "rename Jollibee to McDo" -> match_item:Jollibee, new_item:McDo
            "change Grab category to Transport" -> match_item:Grab, new_category:Transport
            "fix the bread price to 55" -> match_item:bread, new_amount:55
- rename_category: renames ALL expenses in a category to the new category name.
  Example: "rename Apparel to Clothing" -> old_category:Apparel, new_category:Clothing

EXPENSE FORMAT (any order, case-insensitive):
"Jollibee 120" -> item:Jollibee, infer Food
"120 Grab" -> item:Grab, infer Transport
"Kimpao 45 Food" -> item:Kimpao, cat:Food (EXPLICIT - never override)
"Shoes 250 Apparel" -> item:Shoes, cat:Apparel (EXPLICIT)
"coffee 65, Grab 80" -> 2 expenses
Multi-line input -> extract all expenses

CATEGORY RULE: If user states a category word, USE IT EXACTLY. Never replace explicit categories.
If no category stated, infer intelligently.
Any word is a valid category (Apparel, Hobbies, Pets, etc).

QUERY RULE: Compute answers directly from data above. Do not say "I will check".

Return ONLY the JSON object, nothing else.
''';

    try {
      final res = await http.post(
        Uri.parse("https://api.openai.com/v1/chat/completions"),
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer $openAiKey",
        },
        body: jsonEncode({
          "model": "gpt-4.1-mini",
          "messages": [
            {"role": "user", "content": prompt}
          ]
        }),
      ).timeout(const Duration(seconds: 30));

      if (res.statusCode != 200) {
        debugPrint("OpenAI HTTP ${res.statusCode}: ${res.body}");
        return {
          "action": "chat",
          "reply": "I'm having trouble connecting right now. Check your internet and try again!",
          "data": {}
        };
      }

      final responseData = jsonDecode(res.body) as Map<String, dynamic>;

      if (responseData.containsKey("error")) {
        final msg = (responseData["error"] as Map)["message"] ?? "API error";
        debugPrint("OpenAI API error: $msg");
        return {"action": "chat", "reply": "API error: $msg", "data": {}};
      }

      final choices = responseData["choices"] as List?;
      if (choices == null || choices.isEmpty) {
        return {"action": "chat", "reply": "No response from AI. Please try again!", "data": {}};
      }

      String text = (choices[0]["message"]?["content"] ?? "") as String;
      // Strip any markdown fences
      text = text.replaceAll(RegExp(r'```json\s*|```\s*'), '').trim();

      if (text.isEmpty) {
        return {"action": "chat", "reply": "Got an empty reply. Please try again!", "data": {}};
      }

      final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(text);
      if (jsonMatch == null) {
        debugPrint("No JSON in response: $text");
        return {"action": "chat", "reply": text.length < 300 ? text : "Got a confusing response. Try again!", "data": {}};
      }

      final parsed = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;
      if (!parsed.containsKey("action")) parsed["action"] = "chat";
      if ((parsed["reply"] as String? ?? "").trim().isEmpty) {
        parsed["reply"] = "Got it! Anything else?";
      }
      if (!parsed.containsKey("data")) parsed["data"] = <String, dynamic>{};

      return parsed;
    } on http.ClientException catch (e) {
      debugPrint("Network error: $e");
      return {"action": "chat", "reply": "Network error. Please check your connection!", "data": {}};
    } on FormatException catch (e) {
      debugPrint("JSON parse error: $e");
      return {"action": "chat", "reply": "Got a confusing response. Please try again!", "data": {}};
    } catch (e) {
      debugPrint("askBrain error: $e");
      return {"action": "chat", "reply": "Something went wrong. Please try again!", "data": {}};
    }
  }

  // ─── Handle Message ───────────────────────────────────
  Future<void> handle(String input) async {
    input = input.trim();
    if (input.isEmpty) return;

    setState(() {
      messages.add({"role": "user", "text": input});
      isLoading = true;
    });
    controller.clear();
    _scrollToBottom();

    // ── FAST-PATH: no API call needed ────────────────────
    if (_tryLocalIntent(input)) {
      if (mounted) setState(() => isLoading = false);
      return;
    }

    // ── AI handles everything else ───────────────────────
    try {
      final result = await askBrain(input);
      final action = (result["action"] as String? ?? "chat").trim();
      final reply  = (result["reply"]  as String? ?? "").trim();
      final data   = result["data"]    as Map<String, dynamic>? ?? {};

      switch (action) {
        case "set_budget":
          final amt = (data["amount"] as num?)?.toDouble() ?? 0;
          if (amt > 0) {
            budget = amt;
            await saveAll();
            refreshNotifier.value++;
          }
          _addBot(reply.isNotEmpty
              ? reply
              : "Budget updated to \u20B1${budget.toStringAsFixed(0)}!");
          break;

        case "add_expense":
          final rawList = data["expenses"];
          int added = 0;
          if (rawList is List && rawList.isNotEmpty) {
            for (var e in rawList) {
              final amt = ((e["amount"] ?? 0) as num).toDouble();
              if (amt <= 0) continue;
              final item = _titleCase((e["item"] ?? "Unknown").toString().trim());
              String cat = (e["category"] as String?)?.trim() ?? "Other";
              if (cat.isEmpty) cat = "Other";
              learnedCategories[item.toLowerCase()] = cat;
              expenses.add({
                "amount": amt,
                "item": item,
                "category": cat,
                "date": DateTime.now().toIso8601String(),
              });
              added++;
            }
            if (added > 0) {
              await saveAll();
              refreshNotifier.value++;
              await NotifService.checkBudgetAlerts();
            }
          }
          _addBot(reply.isNotEmpty
              ? reply
              : (added > 0
                  ? "Logged $added expense${added > 1 ? 's' : ''}!"
                  : "Couldn't parse that expense. Try: \"Jollibee 120\""));
          break;

        case "delete":
          final itemName = (data["item"] ?? "").toString().toLowerCase().trim();
          if (itemName.isNotEmpty) {
            final before = expenses.length;
            expenses.removeWhere(
                (e) => e["item"].toString().toLowerCase().contains(itemName));
            final removed = before - expenses.length;
            await saveAll();
            refreshNotifier.value++;
            _addBot(reply.isNotEmpty
                ? reply
                : (removed > 0
                    ? "Removed $removed expense(s) matching \"$itemName\"."
                    : "No expenses found matching \"$itemName\"."));
          } else {
            _addBot(reply.isNotEmpty ? reply : "Which expense should I remove?");
          }
          break;

        case "delete_category":
          final catName = (data["category"] ?? "").toString().trim();
          if (catName.isNotEmpty) {
            final before = expenses.length;
            expenses.removeWhere((e) =>
                e["category"].toString().toLowerCase() ==
                catName.toLowerCase());
            learnedCategories.removeWhere(
                (k, v) => v.toLowerCase() == catName.toLowerCase());
            final removed = before - expenses.length;
            await saveAll();
            refreshNotifier.value++;
            _addBot(reply.isNotEmpty
                ? reply
                : (removed > 0
                    ? "Removed $removed \"$catName\" expense(s)."
                    : "No expenses found under \"$catName\"."));
          } else {
            _addBot(reply.isNotEmpty ? reply : "Which category should I remove?");
          }
          break;

        case "edit_expense":
          final matchItem   = (data["match_item"]    as String? ?? "").toLowerCase().trim();
          final newItem     = data["new_item"]     as String?;
          final newCat      = data["new_category"] as String?;
          final newAmt      = (data["new_amount"]  as num?)?.toDouble();
          int editCount = 0;
          if (matchItem.isNotEmpty) {
            for (int i = 0; i < expenses.length; i++) {
              if (expenses[i]["item"].toString().toLowerCase().contains(matchItem)) {
                final updated = Map<String, dynamic>.from(expenses[i]);
                if (newItem != null && newItem.isNotEmpty) updated["item"] = _titleCase(newItem);
                if (newCat  != null && newCat.isNotEmpty)  updated["category"] = newCat;
                if (newAmt  != null && newAmt > 0)          updated["amount"]   = newAmt;
                expenses[i] = updated;
                editCount++;
              }
            }
            if (editCount > 0) { await saveAll(); refreshNotifier.value++; }
          }
          _addBot(reply.isNotEmpty
              ? reply
              : (editCount > 0
                  ? "Updated $editCount expense(s)!"
                  : "Couldn't find an expense matching \"$matchItem\"."));
          break;

        case "rename_category":
          final oldCat = (data["old_category"] as String? ?? "").trim();
          final newCatName = (data["new_category"] as String? ?? "").trim();
          int renameCount = 0;
          if (oldCat.isNotEmpty && newCatName.isNotEmpty) {
            for (int i = 0; i < expenses.length; i++) {
              if (expenses[i]["category"].toString().toLowerCase() == oldCat.toLowerCase()) {
                expenses[i] = Map<String, dynamic>.from(expenses[i])..["category"] = newCatName;
                renameCount++;
              }
            }
            learnedCategories.removeWhere((k, v) => v.toLowerCase() == oldCat.toLowerCase());
            if (renameCount > 0) { await saveAll(); refreshNotifier.value++; }
          }
          _addBot(reply.isNotEmpty
              ? reply
              : (renameCount > 0
                  ? "Renamed \"$oldCat\" to \"$newCatName\" on $renameCount expense(s)!"
                  : "No expenses found under \"$oldCat\"."));
          break;

        case "set_daily_limit":
          final newDaily  = data["daily"]  == null ? null : (data["daily"]  as num).toDouble();
          final newWeekly = data["weekly"] == null ? null : (data["weekly"] as num).toDouble();
          if (newDaily  != null) customDailyLimit  = newDaily  < 0 ? 0 : newDaily;
          if (newWeekly != null) customWeeklyLimit = newWeekly < 0 ? 0 : newWeekly;
          await saveAll();
          refreshNotifier.value++;
          _addBot(reply.isNotEmpty ? reply : () {
            final parts = <String>[];
            if (newDaily  != null) parts.add(newDaily  == 0 ? "daily limit reset to auto" : "daily limit set to \u20B1${customDailyLimit.toStringAsFixed(0)}");
            if (newWeekly != null) parts.add(newWeekly == 0 ? "weekly limit reset to auto" : "weekly limit set to \u20B1${customWeeklyLimit.toStringAsFixed(0)}");
            return "✅ Dashboard updated — ${parts.join(' and ')}!";
          }());
          break;

        case "clear_expenses":
          expenses.clear();
          learnedCategories.clear();
          await saveAll();
          refreshNotifier.value++;
          _addBot(reply.isNotEmpty
              ? reply
              : "All expenses cleared! Budget of \u20B1${budget.toStringAsFixed(0)} is still set.");
          break;

        case "clear_all":
          expenses.clear();
          budget = 0;
          learnedCategories.clear();
          await saveAll();
          refreshNotifier.value++;
          _addBot(reply.isNotEmpty ? reply : "Everything cleared. Fresh start!");
          break;

        case "query":
          final mode  = (data["mode"]     as String?) ?? "list";
          final catF  = (data["category"] as String?);
          final timeF = (data["time"]     as String?) ?? "all";

          var filtered = List<Map<String, dynamic>>.from(expenses);

          if (catF != null && catF != "null" && catF.isNotEmpty) {
            filtered = filtered
                .where((e) =>
                    e["category"].toString().toLowerCase() ==
                    catF.toLowerCase())
                .toList();
          }
          switch (timeF) {
            case "today":
              filtered = filtered
                  .where((e) => _isToday(DateTime.parse(e["date"])))
                  .toList();
              break;
            case "week":
              filtered = filtered
                  .where((e) => _isThisWeek(DateTime.parse(e["date"])))
                  .toList();
              break;
            case "month":
              filtered = filtered
                  .where((e) => _isThisMonth(DateTime.parse(e["date"])))
                  .toList();
              break;
          }

          final grandTotal =
              filtered.fold(0.0, (s, e) => s + (e["amount"] as num));

          if (filtered.isEmpty) {
            _addBot(reply.isNotEmpty ? reply : "No expenses found.");
          } else if (mode == "list") {
            final grouped = <String, List<Map<String, dynamic>>>{};
            for (var e in filtered) {
              final k = DateFormat('EEE, MMM d, y')
                  .format(DateTime.parse(e["date"]));
              grouped.putIfAbsent(k, () => []).add(e);
            }
            final buf = StringBuffer();
            if (reply.isNotEmpty) {
              buf.writeln(reply);
              buf.writeln();
            }
            grouped.forEach((date, items) {
              buf.writeln("📅 **$date**");
              for (var e in items) {
                buf.writeln(
                    "  • \u20B1${(e['amount'] as num).toStringAsFixed(0)} — ${e['item']} [${e['category']}]");
              }
              buf.writeln();
            });
            buf.writeln("━━━━━━━━━━━━━━━━");
            buf.write("**Total: \u20B1${grandTotal.toStringAsFixed(2)}**");
            if (budget > 0 && (catF == null || catF == "null")) {
              final rem =
                  budget - expenses.fold(0.0, (s, e) => s + (e["amount"] as num));
              buf.write("  •  Remaining: **\u20B1${rem.toStringAsFixed(2)}**");
            }
            _addBot(buf.toString().trim());
          } else {
            _addBot(reply.isNotEmpty
                ? reply
                : "**Total: \u20B1${grandTotal.toStringAsFixed(2)}**");
          }
          break;

        default: // "chat"
          _addBot(reply.isNotEmpty
              ? reply
              : "I'm here! Ask me anything about your budget 💰");
      }
    } catch (e) {
      debugPrint("handle() error: $e");
      _addBot("Something went wrong — please try again!");
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }


  void _addBot(String text) {
    if (text.trim().isEmpty) text = "I'm here! Ask me anything 💰";
    setState(() => messages.add({"role": "bot", "text": text}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 120), () {
      if (scrollCtrl.hasClients) {
        scrollCtrl.animateTo(scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  void listen() async {
    if (isListening) {
      speech.stop();
      setState(() => isListening = false);
      return;
    }
    final ok = await speech.initialize();
    if (ok) {
      setState(() => isListening = true);
      speech.listen(onResult: (r) {
        if (r.finalResult) {
          setState(() => isListening = false);
          handle(r.recognizedWords);
        }
      });
    }
  }

  // ─── Quick Replies ────────────────────────────────────
  Widget _buildQuickReplies() {
    final chips = [
      {"label": "My Expenses", "icon": Icons.list_alt_rounded,           "cmd": "What are my expenses?"},
      {"label": "Today",       "icon": Icons.today_rounded,              "cmd": "Expenses today"},
      {"label": "This Week",   "icon": Icons.date_range_rounded,         "cmd": "Expenses this week"},
      {"label": "This Month",  "icon": Icons.calendar_month_rounded,     "cmd": "Expenses this month"},
      {"label": "Total",       "icon": Icons.calculate_rounded,          "cmd": "Total this month"},
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: chips.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (ctx, i) {
              final c = chips[i];
              return GestureDetector(
                onTap: () => handle(c["cmd"] as String),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: kSurface2,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF2A2D3E)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(c["icon"] as IconData, color: kAccentLight, size: 14),
                      const SizedBox(width: 5),
                      Text(c["label"] as String,
                          style: const TextStyle(color: kTextSub, fontSize: 12)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: () => _showCommandsSheet(context),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: kAccent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kAccent.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.menu_book_rounded, color: kAccentLight, size: 14),
                SizedBox(width: 6),
                Text("Command Guide — how to log expenses & more",
                    style: TextStyle(color: kAccentLight, fontSize: 12)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  void _showCommandsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        minChildSize: 0.4,
        expand: false,
        builder: (_, sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Center(
              child: Container(
                width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: kTextSub.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const Text("Command Guide",
                style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 18)),
            const SizedBox(height: 16),
            _cmdSection("💸 Log Expenses", [
              ("Jollibee 120",             "Item + amount — AI picks category"),
              ("45 bread Food",            "Amount + item + explicit category"),
              ("Shoes 200 Apparel",        "Custom categories work too!"),
              ("200 on Grab",              "Natural language format"),
              ("Bought coffee 65",         "Any phrasing is fine"),
              ("Jollibee 120, Grab 80",    "Multiple at once (comma-separated)"),
              ("Jollibee 120\nGrab 80",    "Or one per line"),
            ]),
            _cmdSection("🎯 Set Budget", [
              ("Budget 5000",        "Set budget instantly"),
              ("My budget is 3000",  "Natural phrasing works"),
              ("Set budget 10000",   "Explicit command"),
              ("10000 budget",       "Amount first is fine too"),
            ]),
            _cmdSection("📊 View Expenses", [
              ("What are my expenses?",  "See all expenses"),
              ("Expenses today",         "Today only"),
              ("Expenses this week",     "Current week"),
              ("Expenses this month",    "Current month"),
              ("Food expenses",          "Filter by category"),
              ("Total this month",       "Sum for a period"),
              ("How much did I spend?",  "Quick total check"),
            ]),
            _cmdSection("🗑️ Delete Expenses", [
              ("Remove bread",                "Delete by item name"),
              ("Delete Grab",                 "Same as Remove"),
              ("Remove Transportation",       "Delete all in a category"),
              ("Delete all Food expenses",    "Clear a whole category"),
            ]),
            _cmdSection("💡 Insights & Budget", [
              ("Am I over budget?",      "Check budget status"),
              ("Give me tips",           "Spending insights & advice"),
              ("Where am I spending most?", "Top spending categories"),
              ("How much is left?",      "Remaining budget"),
              ("Summarize my spending",  "Overview of all expenses"),
            ]),
            _cmdSection("✏️ Edit Expenses", [
              ("Rename Jollibee to McDo",           "Rename an expense item"),
              ("Change Grab category to Transport",  "Change an item's category"),
              ("Fix the bread price to 55",          "Change an item's amount"),
              ("Rename Apparel to Clothing",         "Rename a whole category"),
            ]),
            _cmdSection("📐 Set Spending Limits", [
              ("Set my daily limit to 200",          "Custom daily limit on dashboard"),
              ("What if 1000 per week, update dashboard", "Set a custom weekly limit"),
              ("Set daily 150 and weekly 800",       "Set both at once"),
              ("Reset my daily limit",               "Go back to auto-calculated"),
              ("Reset my weekly limit",              "Go back to auto-calculated"),
            ]),
            _cmdSection("🧹 Reset & Clear", [
              ("Clear all",          "Reset everything (expenses + budget)"),
              ("Clear expenses",     "Remove expenses, keep budget"),
              ("Start over",         "Same as Clear all"),
            ]),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: kAccent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kAccent.withValues(alpha: 0.3)),
              ),
              child: const Text(
                "💡 Tip: Use any category name — Apparel, Pets, Hobbies, Travel — Budgetero learns and remembers them!",
                style: TextStyle(color: kAccentLight, fontSize: 13, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cmdSection(String title, List<(String, String)> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(title,
              style: const TextStyle(color: kText, fontWeight: FontWeight.w700, fontSize: 15)),
        ),
        ...items.map((item) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () { Navigator.pop(context); handle(item.$1); },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: kSurface2, borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF2A2D3E)),
                  ),
                  child: Text(item.$1,
                      style: const TextStyle(color: kAccentLight, fontSize: 12, fontFamily: 'monospace')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text(item.$2,
                      style: const TextStyle(color: kTextSub, fontSize: 12)),
                ),
              ),
            ],
          ),
        )),
        const Divider(color: Color(0xFF2A2D3E)),
      ],
    );
  }

  // ─── Message Bubble ───────────────────────────────────
  Widget _buildBubble(Map<String, dynamic> m) {
    final isUser = m["role"] == "user";
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 30, height: 30,
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [kAccent, kAccentLight]),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.account_balance_wallet_rounded,
                  size: 16, color: Colors.white),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: isUser ? kAccent : kSurface,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(isUser ? 18 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 18),
                ),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 6,
                      offset: const Offset(0, 2))
                ],
              ),
              child: _richText(m["text"] as String, isUser),
            ),
          ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _richText(String text, bool isUser) {
    final spans = <TextSpan>[];
    final parts = text.split(RegExp(r'\*\*'));
    for (int i = 0; i < parts.length; i++) {
      final subs = parts[i].split(RegExp(r'\*'));
      for (int j = 0; j < subs.length; j++) {
        spans.add(TextSpan(
          text: subs[j],
          style: TextStyle(
            fontWeight: i.isOdd ? FontWeight.bold : FontWeight.normal,
            fontStyle: j.isOdd ? FontStyle.italic : FontStyle.normal,
            color: isUser ? Colors.white : kText,
            fontSize: 14, height: 1.6,
          ),
        ));
      }
    }
    return RichText(text: TextSpan(children: spans));
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Row(children: [
        Container(
          width: 30, height: 30,
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [kAccent, kAccentLight]),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.account_balance_wallet_rounded,
              size: 16, color: Colors.white),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            color: kSurface,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18), topRight: Radius.circular(18),
              bottomRight: Radius.circular(18), bottomLeft: Radius.circular(4),
            ),
          ),
          child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) => _Dot(delay: i * 200))),
        ),
      ]),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(
          14, 10, 14, 12 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(
        color: kSurface,
        border: Border(top: BorderSide(color: Color(0xFF2A2D3E))),
      ),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: controller,
            style: const TextStyle(color: kText, fontSize: 14),
            maxLines: null,
            textInputAction: TextInputAction.send,
            onSubmitted: handle,
            decoration: const InputDecoration(
                hintText: "Type an expense or ask anything..."),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: listen,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 42, height: 42,
            decoration: BoxDecoration(
              color: isListening ? kRed : kSurface2,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                  color: isListening ? kRed : const Color(0xFF2A2D3E)),
            ),
            child: Icon(
              isListening ? Icons.stop_rounded : Icons.mic_rounded,
              color: isListening ? Colors.white : kTextSub,
              size: 20,
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => handle(controller.text),
          child: Container(
            width: 42, height: 42,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [kAccent, kAccentLight],
                  begin: Alignment.topLeft, end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(13),
            ),
            child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: Row(children: [
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [kAccent, kAccentLight]),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.account_balance_wallet_rounded,
                size: 18, color: Colors.white),
          ),
          const SizedBox(width: 10),
          const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("Budgetero",
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            Text("AI Budget Tracker",
                style: TextStyle(fontSize: 10, color: kTextSub, height: 1)),
          ]),
        ]),
        actions: const [],
      ),
      body: Column(children: [
        Expanded(
          child: ListView.builder(
            controller: scrollCtrl,
            padding: const EdgeInsets.symmetric(vertical: 14),
            itemCount: messages.length + (isLoading ? 1 : 0),
            itemBuilder: (ctx, i) {
              if (i == messages.length) return _buildTypingIndicator();
              return _buildBubble(messages[i]);
            },
          ),
        ),
        _buildQuickReplies(),
        _buildInputBar(),
      ]),
    );
  }
}

// ─── Typing Dot ───────────────────────────────────────────
class _Dot extends StatefulWidget {
  final int delay;
  const _Dot({required this.delay});
  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
    _anim = Tween(begin: 0.2, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _ctrl.repeat(reverse: true);
    });
  }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: FadeTransition(
      opacity: _anim,
      child: Container(
          width: 7, height: 7,
          decoration: const BoxDecoration(
              color: kAccentLight, shape: BoxShape.circle)),
    ),
  );
}

// ═══════════════════════════════════════════════════════════
// DASHBOARD SCREEN
// ═══════════════════════════════════════════════════════════
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  Map<String, double> _totals(List<Map<String, dynamic>> list) {
    final map = <String, double>{};
    for (var e in list) {
      map[e["category"]] =
          (map[e["category"]] ?? 0) + (e["amount"] as num);
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: refreshNotifier,
      builder: (_, __, ___) {
        final now    = DateTime.now();
        final total  = expenses.fold(0.0, (s, e) => s + (e["amount"] as num));
        final remain = budget - total;
        final pct    = budget > 0 ? (total / budget).clamp(0.0, 1.0) : 0.0;
        final cats   = _totals(expenses);

        return Scaffold(
          backgroundColor: kBg,
          appBar: AppBar(
            title: Row(children: [
              Container(
                width: 34, height: 34,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [kGreen, Color(0xFF00BCD4)]),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.donut_large_rounded, size: 18, color: Colors.white),
              ),
              const SizedBox(width: 10),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text("Dashboard",
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                Text(DateFormat('MMM d, y').format(now),
                    style: const TextStyle(fontSize: 10, color: kTextSub, height: 1)),
              ]),
            ]),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ── Summary Cards ──
              Row(children: [
                _SummaryCard(label: "Budget", value: "\u20B1${budget.toStringAsFixed(0)}",
                    icon: Icons.account_balance_wallet_rounded, gradient: [kAccent, kAccentLight]),
                const SizedBox(width: 10),
                _SummaryCard(label: "Spent", value: "\u20B1${total.toStringAsFixed(0)}",
                    icon: Icons.trending_up_rounded,
                    gradient: total > budget && budget > 0
                        ? [kRed, const Color(0xFFFF8A80)]
                        : [kGreen, const Color(0xFF00BCD4)]),
                const SizedBox(width: 10),
                _SummaryCard(
                  label: "Left", value: "\u20B1${remain.abs().toStringAsFixed(0)}",
                  icon: remain >= 0 ? Icons.savings_rounded : Icons.warning_rounded,
                  gradient: remain >= 0
                      ? [const Color(0xFF26C281), const Color(0xFF1ABC9C)]
                      : [kRed, const Color(0xFFFF8A80)],
                  subtitle: remain < 0 ? "OVER" : null,
                ),
              ]),
              const SizedBox(height: 16),

              // ── Daily & Weekly Spending Limit Card ──
              if (budget > 0) ...[
                Builder(builder: (ctx) {
                  final now2        = DateTime.now();
                  final daysInMonth = DateUtils.getDaysInMonth(now2.year, now2.month);
                  final daysLeft    = daysInMonth - now2.day + 1;

                  // Days left in current week (Mon-Sun), capped to month end
                  final weekdayNum  = now2.weekday; // 1=Mon, 7=Sun
                  final daysToEndOfWeek = 7 - weekdayNum + 1; // days left incl. today
                  final daysLeftWeek = daysToEndOfWeek.clamp(1, daysLeft);

                  final todaySpent = expenses
                      .where((e) {
                        final d = DateTime.parse(e['date'] as String);
                        return d.year == now2.year && d.month == now2.month && d.day == now2.day;
                      })
                      .fold(0.0, (s, e) => s + (e['amount'] as num));

                  final weekStart  = DateTime(now2.year, now2.month, now2.day)
                      .subtract(Duration(days: now2.weekday - 1));
                  final thisWeekSpent = expenses
                      .where((e) {
                        final d = DateTime.parse(e['date'] as String);
                        return !d.isBefore(weekStart);
                      })
                      .fold(0.0, (s, e) => s + (e['amount'] as num));

                  final remaining2    = budget - total;
                  final autoDailyLimit  = remaining2 > 0 ? remaining2 / daysLeft : 0.0;
                  final autoWeeklyLimit = remaining2 > 0 ? remaining2 / (daysLeft / 7).ceil() : 0.0;
                  // Use custom limits if set, otherwise fall back to auto-calculated
                  final dailyLimit  = customDailyLimit  > 0 ? customDailyLimit  : autoDailyLimit;
                  final weeklyLimit = customWeeklyLimit > 0 ? customWeeklyLimit : autoWeeklyLimit;
                  final isCustomDaily  = customDailyLimit  > 0;
                  final isCustomWeekly = customWeeklyLimit > 0;
                  final isOver      = remaining2 < 0;

                  final dayColor  = isOver ? kRed : todaySpent > dailyLimit  ? const Color(0xFFFFC107) : kGreen;
                  final weekColor = isOver ? kRed : thisWeekSpent > weeklyLimit ? const Color(0xFFFFC107) : kGreen;
                  final cardColor = isOver ? kRed : (todaySpent > dailyLimit || thisWeekSpent > weeklyLimit)
                      ? const Color(0xFFFFC107) : kGreen;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: kSurface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: cardColor.withValues(alpha: 0.35), width: 1.2),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      // ── Header ──
                      Row(children: [
                        Container(
                          width: 32, height: 32,
                          decoration: BoxDecoration(
                            color: cardColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Icon(
                            isOver ? Icons.warning_rounded : Icons.event_note_rounded,
                            color: cardColor, size: 17,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          isOver ? "Over Budget" : "Spending Limits",
                          style: const TextStyle(color: kText, fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                        const Spacer(),
                        Text(
                          "₱${remaining2.abs().toStringAsFixed(0)} ${isOver ? 'over' : 'left'}",
                          style: TextStyle(color: cardColor, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ]),

                      if (isOver) ...[
                        const SizedBox(height: 8),
                        Text(
                          "You've exceeded your budget by ₱${remaining2.abs().toStringAsFixed(0)}. Avoid new expenses!",
                          style: const TextStyle(color: kTextSub, fontSize: 11, height: 1.5),
                        ),
                      ] else ...[
                        const SizedBox(height: 12),
                        // ── Divider ──
                        Container(height: 1, color: const Color(0xFF2A2D3E)),
                        const SizedBox(height: 12),

                        // ── Daily row ──
                        Row(children: [
                          Container(
                            width: 28, height: 28,
                            decoration: BoxDecoration(
                              color: dayColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(Icons.today_rounded, color: dayColor, size: 14),
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              const Text("Today's limit", style: TextStyle(color: kTextSub, fontSize: 11)),
                              if (isCustomDaily) ...[
                                const SizedBox(width: 5),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: kAccent.withValues(alpha: 0.18),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text("custom", style: TextStyle(color: kAccentLight, fontSize: 9, fontWeight: FontWeight.w600)),
                                ),
                              ],
                            ]),
                            Text(
                              "Spent ₱${todaySpent.toStringAsFixed(0)} · $daysLeft day${daysLeft == 1 ? '' : 's'} left in month",
                              style: const TextStyle(color: kTextSub, fontSize: 10),
                            ),
                          ])),
                          Text(
                            "₱${dailyLimit.toStringAsFixed(0)} / day",
                            style: TextStyle(color: dayColor, fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                        ]),

                        const SizedBox(height: 10),

                        // ── Weekly row ──
                        Row(children: [
                          Container(
                            width: 28, height: 28,
                            decoration: BoxDecoration(
                              color: weekColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(Icons.date_range_rounded, color: weekColor, size: 14),
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              const Text("This week's limit", style: TextStyle(color: kTextSub, fontSize: 11)),
                              if (isCustomWeekly) ...[
                                const SizedBox(width: 5),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: kAccent.withValues(alpha: 0.18),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text("custom", style: TextStyle(color: kAccentLight, fontSize: 9, fontWeight: FontWeight.w600)),
                                ),
                              ],
                            ]),
                            Text(
                              "Spent ₱${thisWeekSpent.toStringAsFixed(0)} · $daysLeftWeek day${daysLeftWeek == 1 ? '' : 's'} left in week",
                              style: const TextStyle(color: kTextSub, fontSize: 10),
                            ),
                          ])),
                          Text(
                            "₱${weeklyLimit.toStringAsFixed(0)} / week",
                            style: TextStyle(color: weekColor, fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                        ]),
                      ],
                    ]),
                  );
                }),
              ],

              // ── Budget Progress ──
              if (budget > 0) ...[
                const _SectionHeader("Budget Progress"),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: kSurface, borderRadius: BorderRadius.circular(14)),
                  child: Column(children: [
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text("${(pct * 100).toStringAsFixed(1)}% used",
                          style: const TextStyle(color: kText, fontWeight: FontWeight.w600, fontSize: 13)),
                      Text("\u20B1${total.toStringAsFixed(0)} / \u20B1${budget.toStringAsFixed(0)}",
                          style: const TextStyle(color: kTextSub, fontSize: 12)),
                    ]),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: pct, minHeight: 10, backgroundColor: kSurface2,
                        valueColor: AlwaysStoppedAnimation(
                            pct > 0.9 ? kRed : pct > 0.7 ? const Color(0xFFFFC107) : kGreen),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 16),
              ],

              if (expenses.isEmpty) ...[
                const SizedBox(height: 30),
                Center(
                  child: Column(children: [
                    Container(
                      width: 72, height: 72,
                      decoration: BoxDecoration(
                          gradient: const LinearGradient(colors: [kAccent, kAccentLight]),
                          borderRadius: BorderRadius.circular(22)),
                      child: const Icon(Icons.receipt_long_rounded, size: 36, color: Colors.white),
                    ),
                    const SizedBox(height: 16),
                    const Text("No expenses yet",
                        style: TextStyle(color: kText, fontSize: 17, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    const Text(
                      "Head to Chat and log your first expense!\nTry: \"Jollibee 120\" or \"45 bread Food\"",
                      style: TextStyle(color: kTextSub, fontSize: 13, height: 1.6),
                      textAlign: TextAlign.center,
                    ),
                  ]),
                ),
              ] else ...[

                // ── Pie Chart ──
                if (cats.isNotEmpty) ...[
                  const _SectionHeader("Spending Breakdown"),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                        color: kSurface, borderRadius: BorderRadius.circular(14)),
                    child: Column(children: [
                      SizedBox(
                        height: 200,
                        child: PieChart(PieChartData(
                          sectionsSpace: 2, centerSpaceRadius: 48,
                          sections: cats.entries.map((e) {
                            final color = colorForCategory(e.key);
                            return PieChartSectionData(
                              value: e.value, color: color,
                              title: "${(e.value / total * 100).toStringAsFixed(0)}%",
                              titleStyle: const TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                              radius: 62,
                            );
                          }).toList(),
                        )),
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 12, runSpacing: 8,
                        children: cats.entries.map((e) {
                          final color = colorForCategory(e.key);
                          return Row(mainAxisSize: MainAxisSize.min, children: [
                            Container(width: 9, height: 9,
                                decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                            const SizedBox(width: 4),
                            Text("${e.key} \u20B1${e.value.toStringAsFixed(0)}",
                                style: const TextStyle(color: kTextSub, fontSize: 12)),
                          ]);
                        }).toList(),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 16),
                ],

                // ── By Category (Expandable) ──
                const _SectionHeader("By Category"),
                ...cats.entries.map((e) => _ExpandableCategoryCard(
                  categoryName: e.key, total: e.value, grandTotal: total,
                  catExpenses: expenses.where((exp) => exp["category"] == e.key).toList(),
                )),
                const SizedBox(height: 16),

                // ── Recent Expenses ──
                const _SectionHeader("Recent Expenses"),
                ...expenses.reversed.take(15).map((e) {
                  final color   = colorForCategory(e["category"]);
                  final icon    = iconForCategory(e["category"]);
                  final dateStr = DateFormat('MMM d, y').format(DateTime.parse(e["date"]));
                  return _EditableExpenseRow(
                    expense: e,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                      decoration: BoxDecoration(
                          color: kSurface, borderRadius: BorderRadius.circular(12)),
                      child: Row(children: [
                        Container(
                          width: 34, height: 34,
                          decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10)),
                          child: Icon(icon, color: color, size: 17),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(e["item"], style: const TextStyle(color: kText, fontSize: 13)),
                          Text(e["category"], style: const TextStyle(color: kTextSub, fontSize: 11)),
                        ])),
                        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Text("\u20B1${(e['amount'] as num).toStringAsFixed(0)}",
                              style: const TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 13)),
                          Text(dateStr, style: const TextStyle(color: kTextSub, fontSize: 10)),
                        ]),
                      ]),
                    ),
                  );
                }),
              ],
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }
}

// ─── Expandable Category Card ─────────────────────────────
class _ExpandableCategoryCard extends StatefulWidget {
  final String categoryName;
  final double total, grandTotal;
  final List<Map<String, dynamic>> catExpenses;
  const _ExpandableCategoryCard({
    required this.categoryName,
    required this.total,
    required this.grandTotal,
    required this.catExpenses,
  });
  @override
  State<_ExpandableCategoryCard> createState() =>
      _ExpandableCategoryCardState();
}

class _ExpandableCategoryCardState extends State<_ExpandableCategoryCard>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late AnimationController _ctrl;
  late Animation<double> _size, _rot;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 240));
    _size = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
    _rot  = Tween(begin: 0.0, end: 0.5).animate(_size);
  }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  void _toggle() {
    setState(() => _expanded = !_expanded);
    _expanded ? _ctrl.forward() : _ctrl.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final color  = colorForCategory(widget.categoryName);
    final icon   = iconForCategory(widget.categoryName);
    final catPct = widget.grandTotal > 0 ? widget.total / widget.grandTotal : 0.0;

    return GestureDetector(
      onTap: _toggle,
      onLongPress: () => _showRenameCategorySheet(context, widget.categoryName),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _expanded ? color.withValues(alpha: 0.5) : const Color(0xFF2A2D3E),
            width: _expanded ? 1.5 : 1,
          ),
        ),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(13),
            child: Column(children: [
              Row(children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon, color: color, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.categoryName,
                      style: const TextStyle(color: kText, fontWeight: FontWeight.w600, fontSize: 13)),
                  Text("${(catPct * 100).toStringAsFixed(1)}% · ${widget.catExpenses.length} item(s)",
                      style: const TextStyle(color: kTextSub, fontSize: 11)),
                ])),
                Text("\u20B1${widget.total.toStringAsFixed(0)}",
                    style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(width: 6),
                RotationTransition(
                    turns: _rot,
                    child: const Icon(Icons.keyboard_arrow_down_rounded,
                        color: kTextSub, size: 20)),
              ]),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: catPct, minHeight: 4, backgroundColor: kSurface2,
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
            ]),
          ),
          SizeTransition(
            sizeFactor: _size,
            child: Column(children: [
              Container(height: 1, color: color.withValues(alpha: 0.15)),
              ...widget.catExpenses.map((exp) {
                final dt = DateFormat('MMM d · h:mm a')
                    .format(DateTime.parse(exp["date"]));
                return _EditableExpenseRow(
                  expense: exp,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
                    child: Row(children: [
                      Container(
                          width: 5, height: 5,
                          margin: const EdgeInsets.only(right: 10),
                          decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(exp["item"],
                            style: const TextStyle(color: kText, fontSize: 12)),
                        Text(dt, style: const TextStyle(color: kTextSub, fontSize: 10)),
                      ])),
                      Text("\u20B1${(exp['amount'] as num).toStringAsFixed(0)}",
                          style: TextStyle(
                              color: color, fontWeight: FontWeight.w600, fontSize: 12)),
                      const SizedBox(width: 6),
                      const Icon(Icons.edit_rounded, color: kTextSub, size: 12),
                    ]),
                  ),
                );
              }),
              const SizedBox(height: 6),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ─── Editable Expense Row (long-press to edit) ────────────
class _EditableExpenseRow extends StatelessWidget {
  final Map<String, dynamic> expense;
  final Widget child;
  const _EditableExpenseRow({required this.expense, required this.child});

  void _showSheet(BuildContext ctx) {
    final idxList = expenses
        .asMap()
        .entries
        .where((en) => en.value["date"] == expense["date"] && en.value["item"] == expense["item"])
        .map((en) => en.key)
        .toList();
    if (idxList.isEmpty) return;
    final idx = idxList.first;

    final itemCtrl = TextEditingController(text: expense["item"] as String);
    final catCtrl  = TextEditingController(text: expense["category"] as String);
    final amtCtrl  = TextEditingController(text: (expense["amount"] as num).toStringAsFixed(0));

    showModalBottomSheet(
      context: ctx,
      backgroundColor: kSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => StatefulBuilder(
        builder: (ctx2, ss) => Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx2).viewInsets.bottom + 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: kTextSub.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(2)))),
            Row(children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: colorForCategory(expense["category"] as String).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(iconForCategory(expense["category"] as String),
                    color: colorForCategory(expense["category"] as String), size: 18),
              ),
              const SizedBox(width: 10),
              const Text("Edit Expense", style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 17)),
              const Spacer(),
              const Text("Hold category card to rename it",
                  style: TextStyle(color: kTextSub, fontSize: 10)),
            ]),
            const SizedBox(height: 18),
            _EField("Item Name", itemCtrl, Icons.label_rounded),
            const SizedBox(height: 10),
            _EField("Category", catCtrl, Icons.category_rounded),
            const SizedBox(height: 10),
            _EField("Amount (₱)", amtCtrl, Icons.payments_rounded, isNumber: true),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: () {
                final newAmt = double.tryParse(amtCtrl.text.trim()) ?? (expense["amount"] as num).toDouble();
                final newItem = itemCtrl.text.trim().isEmpty ? expense["item"] as String : itemCtrl.text.trim();
                final newCat  = catCtrl.text.trim().isEmpty  ? expense["category"] as String : catCtrl.text.trim();
                final updated = Map<String, dynamic>.from(expense);
                updated["item"]     = newItem.split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1).toLowerCase()).join(' ');
                updated["category"] = newCat;
                updated["amount"]   = newAmt;
                expenses[idx] = updated;
                saveAll();
                refreshNotifier.value++;
                Navigator.pop(ctx);
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [kAccent, kAccentLight]),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Center(child: Text("Save Changes",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15))),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: () => _showSheet(context),
      child: child,
    );
  }
}

// ─── Edit field widget ─────────────────────────────────────
class _EField extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  final IconData icon;
  final bool isNumber;
  const _EField(this.label, this.ctrl, this.icon, {this.isNumber = false});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: kTextSub, fontSize: 12, fontWeight: FontWeight.w500)),
      const SizedBox(height: 5),
      TextField(
        controller: ctrl,
        keyboardType: isNumber ? TextInputType.number : TextInputType.text,
        style: const TextStyle(color: kText, fontSize: 14),
        decoration: InputDecoration(
          prefixIcon: Icon(icon, color: kTextSub, size: 18),
          filled: true, fillColor: kSurface2,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
    ],
  );
}

// ─── Rename Category Sheet ─────────────────────────────────
void _showRenameCategorySheet(BuildContext ctx, String currentName) {
  final ctrl = TextEditingController(text: currentName);
  showModalBottomSheet(
    context: ctx,
    backgroundColor: kSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(color: kTextSub.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(2)))),
        Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: colorForCategory(currentName).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(iconForCategory(currentName), color: colorForCategory(currentName), size: 18),
          ),
          const SizedBox(width: 10),
          const Text("Rename Category", style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 17)),
        ]),
        const SizedBox(height: 6),
        Text('Renames all expenses under "$currentName"',
            style: const TextStyle(color: kTextSub, fontSize: 12)),
        const SizedBox(height: 18),
        _EField("Category Name", ctrl, Icons.category_rounded),
        const SizedBox(height: 20),
        GestureDetector(
          onTap: () {
            final newName = ctrl.text.trim();
            if (newName.isEmpty || newName == currentName) { Navigator.pop(ctx); return; }
            for (int i = 0; i < expenses.length; i++) {
              if (expenses[i]["category"].toString() == currentName) {
                expenses[i] = Map<String, dynamic>.from(expenses[i])..["category"] = newName;
              }
            }
            learnedCategories.removeWhere((k, v) => v == currentName);
            saveAll();
            refreshNotifier.value++;
            Navigator.pop(ctx);
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [kAccent, kAccentLight]),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Center(child: Text("Rename Category",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15))),
          ),
        ),
      ]),
    ),
  );
}

// ─── Summary Card ─────────────────────────────────────────
class _SummaryCard extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final List<Color> gradient;
  final String? subtitle;
  const _SummaryCard({
    required this.label, required this.value,
    required this.icon, required this.gradient, this.subtitle,
  });
  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kSurface, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A2D3E)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 30, height: 30,
          decoration: BoxDecoration(
              gradient: LinearGradient(colors: gradient),
              borderRadius: BorderRadius.circular(9)),
          child: Icon(icon, color: Colors.white, size: 14),
        ),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
          child: Text(value,
              style: const TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 15)),
        ),
        Text(subtitle ?? label,
            style: TextStyle(
              color: subtitle != null ? kRed : kTextSub, fontSize: 10,
              fontWeight: subtitle != null ? FontWeight.bold : FontWeight.normal,
            )),
      ]),
    ),
  );
}

// ─── Section Header ───────────────────────────────────────
class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(title,
        style: const TextStyle(
            color: kText, fontWeight: FontWeight.w700,
            fontSize: 14, letterSpacing: 0.3)),
  );
}