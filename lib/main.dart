import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const IYieldApp());
}

class IYieldApp extends StatelessWidget {
  const IYieldApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iYield',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const YieldScreen(),
    );
  }
}

class YieldResult {
  final String ticker;
  final double currentPrice;
  final double sumDistributions;
  final double grossYield;
  final double afterTaxYield;
  final bool qualifies;
  final String? reason;

  const YieldResult({
    required this.ticker,
    required this.currentPrice,
    required this.sumDistributions,
    required this.grossYield,
    required this.afterTaxYield,
    required this.qualifies,
    this.reason,
  });

  factory YieldResult.doesNotQualify({
    required String ticker,
    required double currentPrice,
    required String reason,
  }) {
    return YieldResult(
      ticker: ticker,
      currentPrice: currentPrice,
      sumDistributions: 0,
      grossYield: 0,
      afterTaxYield: 0,
      qualifies: false,
      reason: reason,
    );
  }
}

class YieldScreen extends StatefulWidget {
  const YieldScreen({super.key});

  @override
  State<YieldScreen> createState() => _YieldScreenState();
}

class _YieldScreenState extends State<YieldScreen> {
  final _tickerCtrl = TextEditingController();
  final _federalCtrl = TextEditingController();
  final _stateCtrl = TextEditingController();
  final _localCtrl = TextEditingController(text: '0');

  bool _loading = false;
  String? _error;
  YieldResult? _result;

  static const _kFederal = 'rate_federal';
  static const _kState = 'rate_state';
  static const _kLocal = 'rate_local';

  @override
  void initState() {
    super.initState();
    _loadSavedRates();
  }

  Future<void> _loadSavedRates() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _federalCtrl.text = prefs.getString(_kFederal) ?? '';
      _stateCtrl.text = prefs.getString(_kState) ?? '';
      _localCtrl.text = prefs.getString(_kLocal) ?? '0';
    });
  }

  Future<void> _saveRates() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFederal, _federalCtrl.text);
    await prefs.setString(_kState, _stateCtrl.text);
    await prefs.setString(_kLocal, _localCtrl.text);
  }

  @override
  void dispose() {
    _tickerCtrl.dispose();
    _federalCtrl.dispose();
    _stateCtrl.dispose();
    _localCtrl.dispose();
    super.dispose();
  }

  Future<void> _calculate() async {
    final ticker = _tickerCtrl.text.trim().toUpperCase();
    if (ticker.isEmpty) {
      setState(() => _error = 'Enter a ticker.');
      return;
    }
    final fed = double.tryParse(_federalCtrl.text.trim());
    final state = double.tryParse(_stateCtrl.text.trim());
    final localText = _localCtrl.text.trim();
    final local = double.tryParse(localText.isEmpty ? '0' : localText);
    if (fed == null || state == null || local == null) {
      setState(() => _error = 'Tax rates must be numeric (e.g. 32 for 32%).');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _result = null;
    });

    await _saveRates();

    try {
      final result = await _fetchYield(
        ticker: ticker,
        federalPct: fed,
        statePct: state,
        localPct: local,
      );
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Lookup failed: $e';
        _loading = false;
      });
    }
  }

  Future<YieldResult> _fetchYield({
    required String ticker,
    required double federalPct,
    required double statePct,
    required double localPct,
  }) async {
    final uri = Uri.parse(
        'https://query2.finance.yahoo.com/v8/finance/chart/$ticker?interval=1mo&range=1y&events=div');
    final resp = await http.get(uri, headers: {
      'User-Agent':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15',
    });
    if (resp.statusCode != 200) {
      throw 'HTTP ${resp.statusCode}';
    }
    final body = json.decode(resp.body) as Map<String, dynamic>;
    final chart = body['chart'] as Map<String, dynamic>?;
    final err = chart?['error'];
    if (err != null) {
      throw err is Map ? (err['description'] ?? err.toString()) : err.toString();
    }
    final results = chart?['result'] as List<dynamic>?;
    if (results == null || results.isEmpty) {
      throw 'No data for "$ticker".';
    }
    final r0 = results.first as Map<String, dynamic>;
    final meta = r0['meta'] as Map<String, dynamic>?;
    final price = (meta?['regularMarketPrice'] as num?)?.toDouble();
    if (price == null) {
      throw 'Missing current price for "$ticker".';
    }

    final events = r0['events'] as Map<String, dynamic>?;
    final dividends = events?['dividends'] as Map<String, dynamic>?;
    if (dividends == null || dividends.isEmpty) {
      return YieldResult.doesNotQualify(
        ticker: ticker,
        currentPrice: price,
        reason: 'no distributions in last 12 months',
      );
    }

    double sum = 0;
    for (final entry in dividends.values) {
      final amt = (entry as Map<String, dynamic>)['amount'];
      if (amt is num) sum += amt.toDouble();
    }

    final grossYield = sum / price;
    final combined = (federalPct + statePct + localPct) / 100.0;
    final afterTax = grossYield * (1 - combined);

    return YieldResult(
      ticker: ticker,
      currentPrice: price,
      sumDistributions: sum,
      grossYield: grossYield,
      afterTaxYield: afterTax,
      qualifies: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('iYield')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _tickerCtrl,
                decoration: const InputDecoration(
                  labelText: 'Ticker',
                  border: OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                inputFormatters: [
                  TextInputFormatter.withFunction((oldVal, newVal) {
                    return newVal.copyWith(text: newVal.text.toUpperCase());
                  }),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _federalCtrl,
                decoration: const InputDecoration(
                  labelText: 'Federal marginal rate (%)',
                  border: OutlineInputBorder(),
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _stateCtrl,
                decoration: const InputDecoration(
                  labelText: 'State marginal rate (%)',
                  border: OutlineInputBorder(),
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _localCtrl,
                decoration: const InputDecoration(
                  labelText: 'Local/city marginal rate (%)',
                  border: OutlineInputBorder(),
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loading ? null : _calculate,
                child: _loading
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Calculate'),
              ),
              const SizedBox(height: 16),
              if (_error != null)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!),
                  ),
                ),
              if (_result != null) _ResultCard(result: _result!),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final YieldResult result;
  const _ResultCard({required this.result});

  String _money(double v) => '\$${v.toStringAsFixed(2)}';
  String _pct(double v) => '${(v * 100).toStringAsFixed(2)}%';

  @override
  Widget build(BuildContext context) {
    final r = result;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r.ticker,
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            _row('Current price', _money(r.currentPrice)),
            if (r.qualifies) ...[
              _row('Trailing 12mo distributions', _money(r.sumDistributions)),
              _row('Gross yield', _pct(r.grossYield)),
              _row('After-tax effective yield', _pct(r.afterTaxYield)),
              const SizedBox(height: 8),
              const Text('Qualifies',
                  style: TextStyle(
                      color: Colors.green, fontWeight: FontWeight.bold)),
            ] else ...[
              const SizedBox(height: 8),
              Text('Does not qualify (${r.reason})',
                  style: const TextStyle(
                      color: Colors.red, fontWeight: FontWeight.bold)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
