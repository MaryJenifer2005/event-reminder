import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';

final plugin = FlutterLocalNotificationsPlugin();

// Phone must include country code, e.g. 919876543210
String _digits(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

Future<void> sendWhatsApp(String phone, String msg) async {
  final uri = Uri.parse(
      'https://wa.me/${_digits(phone)}?text=${Uri.encodeComponent(msg)}');
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

Future<void> sendSms(String phone, String msg) async {
  final uri = Uri(scheme: 'sms', path: phone, queryParameters: {'body': msg});
  await launchUrl(uri);
}

Future<void> openWishFromPayload(String? payload) async {
  if (payload == null) return;
  final m = jsonDecode(payload);
  await sendWhatsApp(m['phone'], m['msg']);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation('Asia/Kolkata')); // change if outside India
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    ),
    onDidReceiveNotificationResponse: (r) => openWishFromPayload(r.payload),
  );
  final android = plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await android?.requestNotificationsPermission();
  await android?.requestExactAlarmsPermission();

  final launch = await plugin.getNotificationAppLaunchDetails();
  if (launch?.didNotificationLaunchApp ?? false) {
    openWishFromPayload(launch!.notificationResponse?.payload);
  }
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: const EventsPage(),
  ));
}

class EventsPage extends StatefulWidget {
  const EventsPage({super.key});
  @override
  State<EventsPage> createState() => _EventsPageState();
}

class _EventsPageState extends State<EventsPage> {
  List<Map<String, dynamic>> events = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('events');
    if (raw != null) {
      events = List<Map<String, dynamic>>.from(
          (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e)));
    }
    setState(() {});
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('events', jsonEncode(events));
  }

  // Next upcoming time for (event date - daysBefore) at the given hour
  tz.TZDateTime _next(DateTime d, int daysBefore, int hour) {
    final now = tz.TZDateTime.now(tz.local);
    var t = tz.TZDateTime(tz.local, now.year, d.month, d.day - daysBefore, hour);
    if (t.isBefore(now)) {
      t = tz.TZDateTime(
          tz.local, now.year + 1, d.month, d.day - daysBefore, hour);
    }
    return t;
  }

  NotificationDetails get _details => const NotificationDetails(
        android: AndroidNotificationDetails('events', 'Event reminders',
            importance: Importance.high, priority: Priority.high),
        iOS: DarwinNotificationDetails(),
      );

  Future<void> _schedule(Map<String, dynamic> e) async {
    final id = e['id'] as int;
    final d = DateTime.parse(e['date']);
    await plugin.cancel(id * 2);
    await plugin.cancel(id * 2 + 1);

    // 1) Day before, 9 AM: shows the event name
    await plugin.zonedSchedule(
      id * 2,
      'Tomorrow: ${e['title']}',
      "Don't forget ${e['title']} tomorrow!",
      _next(d, 1, 9),
      _details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.dateAndTime, // repeats yearly
    );

    // 2) Event day, 8 AM: tap to send wishes
    if ((e['phone'] as String).isNotEmpty) {
      await plugin.zonedSchedule(
        id * 2 + 1,
        'Today: ${e['title']}',
        'Tap to send your wishes',
        _next(d, 0, 8),
        _details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.dateAndTime,
        payload: jsonEncode({'phone': e['phone'], 'msg': e['msg']}),
      );
    }
  }

  Future<void> _edit({Map<String, dynamic>? existing}) async {
    final title = TextEditingController(text: existing?['title'] ?? '');
    final phone = TextEditingController(text: existing?['phone'] ?? '');
    final msg = TextEditingController(
        text: existing?['msg'] ?? 'Wishing you a very happy day! 🎉');
    DateTime? date = existing != null ? DateTime.parse(existing['date']) : null;

    await showDialog(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: Text(existing == null ? 'New event' : 'Edit event'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: title,
                  decoration: const InputDecoration(
                      labelText: 'Event (e.g. Amma Birthday)')),
              TextField(
                  controller: phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                      labelText: 'Phone with country code (919876543210)')),
              TextField(
                  controller: msg,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Wish message')),
              TextButton(
                onPressed: () async {
                  final d = await showDatePicker(
                      context: c,
                      initialDate: date ?? DateTime.now(),
                      firstDate: DateTime(1950),
                      lastDate: DateTime(2100));
                  if (d != null) setD(() => date = d);
                },
                child: Text(date == null
                    ? 'Pick date'
                    : '${date!.day}/${date!.month}/${date!.year}'),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            TextButton(
              onPressed: () async {
                if (title.text.isEmpty || date == null) return;
                final e = existing ??
                    {
                      'id': events.isEmpty
                          ? 1
                          : (events
                                  .map((x) => x['id'] as int)
                                  .reduce((a, b) => a > b ? a : b) +
                              1)
                    };
                e['title'] = title.text;
                e['phone'] = phone.text.trim();
                e['msg'] = msg.text;
                e['date'] = date!.toIso8601String();
                if (existing == null) events.add(e);
                await _save();
                await _schedule(e);
                setState(() {});
                if (c.mounted) Navigator.pop(c);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Event Wishes')),
      floatingActionButton: FloatingActionButton(
          onPressed: () => _edit(), child: const Icon(Icons.add)),
      body: events.isEmpty
          ? const Center(child: Text('Tap + to add a birthday or anniversary'))
          : ListView(
              children: events.map((e) {
                final d = DateTime.parse(e['date']);
                final hasPhone = (e['phone'] as String).isNotEmpty;
                return ListTile(
                  title: Text(e['title']),
                  subtitle:
                      Text('${d.day}/${d.month}/${d.year}  ${e['phone']}'),
                  onTap: () => _edit(existing: e),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (hasPhone)
                      IconButton(
                          icon: const Icon(Icons.chat, color: Colors.green),
                          tooltip: 'WhatsApp',
                          onPressed: () => sendWhatsApp(e['phone'], e['msg'])),
                    if (hasPhone)
                      IconButton(
                          icon: const Icon(Icons.sms),
                          tooltip: 'SMS',
                          onPressed: () => sendSms(e['phone'], e['msg'])),
                    IconButton(
                      icon: const Icon(Icons.delete),
                      onPressed: () async {
                        await plugin.cancel(e['id'] * 2);
                        await plugin.cancel(e['id'] * 2 + 1);
                        events.remove(e);
                        await _save();
                        setState(() {});
                      },
                    ),
                  ]),
                );
              }).toList(),
            ),
    );
  }
}
