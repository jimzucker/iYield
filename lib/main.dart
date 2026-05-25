// Copyright 2026 Jim Zucker
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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

class DistributionEntry {
  final DateTime date;
  final double amount;
  const DistributionEntry({required this.date, required this.amount});
}

class MonthlyClose {
  final DateTime monthStart;
  final double? close;
  const MonthlyClose({required this.monthStart, required this.close});
}

class YieldResult {
  final String ticker;
  final double currentPrice;
  final double sumDistributions;
  // 1) Simple TTM: sum(dist) / current_price
  final double grossYield;
  final double afterTaxYield;
  // 2) Compounded DRIP: prod(1 + d_t / P_t) - 1
  final double compoundedGrossYield;
  final double compoundedAfterTaxYield;
  // 3) Average-price denominator: sum(dist) / mean(monthly_closes)
  final double avgPriceGrossYield;
  final double avgPriceAfterTaxYield;
  // 4) TWR including price changes: prod(1 + (P_{t+1} + d_t) / P_t - 1) - 1
  final double twrGross;
  final double twrAfterTax;
  final List<DistributionEntry> distributions;
  final List<MonthlyClose> monthlyCloses;
  final bool qualifies;
  final String? reason;

  const YieldResult({
    required this.ticker,
    required this.currentPrice,
    required this.sumDistributions,
    required this.grossYield,
    required this.afterTaxYield,
    required this.compoundedGrossYield,
    required this.compoundedAfterTaxYield,
    required this.avgPriceGrossYield,
    required this.avgPriceAfterTaxYield,
    required this.twrGross,
    required this.twrAfterTax,
    required this.distributions,
    required this.monthlyCloses,
    required this.qualifies,
    this.reason,
  });

  factory YieldResult.doesNotQualify({
    required String ticker,
    required double currentPrice,
    required String reason,
    List<MonthlyClose> monthlyCloses = const [],
  }) {
    return YieldResult(
      ticker: ticker,
      currentPrice: currentPrice,
      sumDistributions: 0,
      grossYield: 0,
      afterTaxYield: 0,
      compoundedGrossYield: 0,
      compoundedAfterTaxYield: 0,
      avgPriceGrossYield: 0,
      avgPriceAfterTaxYield: 0,
      twrGross: 0,
      twrAfterTax: 0,
      distributions: const [],
      monthlyCloses: monthlyCloses,
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

  static const _kTicker = 'last_ticker';
  static const _kFederal = 'rate_federal';
  static const _kState = 'rate_state';
  static const _kLocal = 'rate_local';

  @override
  void initState() {
    super.initState();
    _loadSavedInputs();
  }

  Future<void> _loadSavedInputs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _tickerCtrl.text = prefs.getString(_kTicker) ?? '';
      _federalCtrl.text = prefs.getString(_kFederal) ?? '';
      _stateCtrl.text = prefs.getString(_kState) ?? '';
      _localCtrl.text = prefs.getString(_kLocal) ?? '0';
    });
  }

  Future<void> _saveInputs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTicker, _tickerCtrl.text.trim().toUpperCase());
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

    await _saveInputs();

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

    final timestamps = (r0['timestamp'] as List<dynamic>?)
            ?.map((e) => (e as num).toInt())
            .toList() ??
        const <int>[];
    final closes = ((r0['indicators']?['quote'] as List<dynamic>?)
                ?.first as Map<String, dynamic>?)?['close']
            as List<dynamic>? ??
        const [];

    final monthlyCloses = <MonthlyClose>[
      for (int i = 0; i < timestamps.length; i++)
        MonthlyClose(
          monthStart: DateTime.fromMillisecondsSinceEpoch(
              timestamps[i] * 1000,
              isUtc: true),
          close: (i < closes.length && closes[i] is num)
              ? (closes[i] as num).toDouble()
              : null,
        ),
    ];

    final events = r0['events'] as Map<String, dynamic>?;
    final dividends = events?['dividends'] as Map<String, dynamic>?;
    if (dividends == null || dividends.isEmpty) {
      return YieldResult.doesNotQualify(
        ticker: ticker,
        currentPrice: price,
        reason: 'no distributions in last 12 months',
        monthlyCloses: monthlyCloses,
      );
    }

    final distributionList = <DistributionEntry>[];

    double sum = 0;
    double compoundFactorGross = 1;
    double compoundFactorNet = 1;
    final combined = (federalPct + statePct + localPct) / 100.0;

    // Bucket distributions by bar period [bars[i], bars[i+1])
    final divByBar = List<double>.filled(timestamps.length, 0);

    for (final entry in dividends.values) {
      final m = entry as Map<String, dynamic>;
      final amt = (m['amount'] as num?)?.toDouble();
      final divTs = (m['date'] as num?)?.toInt();
      if (amt == null || divTs == null) continue;
      sum += amt;
      distributionList.add(DistributionEntry(
        date: DateTime.fromMillisecondsSinceEpoch(divTs * 1000, isUtc: true),
        amount: amt,
      ));

      final barIdx = _barIndexAt(divTs, timestamps);
      if (barIdx >= 0 && barIdx < divByBar.length) {
        divByBar[barIdx] += amt;
      }

      final priceAtDiv = _priceAt(divTs, timestamps, closes) ?? price;
      compoundFactorGross *= 1 + amt / priceAtDiv;
      compoundFactorNet *= 1 + (amt * (1 - combined)) / priceAtDiv;
    }
    distributionList.sort((a, b) => b.date.compareTo(a.date));

    final grossYield = sum / price;
    final afterTax = grossYield * (1 - combined);
    final compoundedGross = compoundFactorGross - 1;
    final compoundedNet = compoundFactorNet - 1;

    // Average-price denominator
    final validCloses = closes
        .whereType<num>()
        .map((n) => n.toDouble())
        .where((v) => v > 0)
        .toList();
    final avgPrice = validCloses.isEmpty
        ? price
        : validCloses.reduce((a, b) => a + b) / validCloses.length;
    final avgGross = sum / avgPrice;
    final avgNet = avgGross * (1 - combined);

    // TWR using monthly closes: r_t = (P_{t+1} + d_t) / P_t - 1
    double twrFactorGross = 1;
    double twrFactorNet = 1;
    for (int i = 0; i + 1 < timestamps.length; i++) {
      final p0 = i < closes.length ? closes[i] : null;
      final p1 = (i + 1) < closes.length ? closes[i + 1] : null;
      if (p0 is! num || p1 is! num) continue;
      if (p0 <= 0) continue;
      final d = i < divByBar.length ? divByBar[i] : 0.0;
      twrFactorGross *= (p1.toDouble() + d) / p0.toDouble();
      twrFactorNet *= (p1.toDouble() + d * (1 - combined)) / p0.toDouble();
    }
    final twrGross = twrFactorGross - 1;
    final twrNet = twrFactorNet - 1;

    return YieldResult(
      ticker: ticker,
      currentPrice: price,
      sumDistributions: sum,
      grossYield: grossYield,
      afterTaxYield: afterTax,
      compoundedGrossYield: compoundedGross,
      compoundedAfterTaxYield: compoundedNet,
      avgPriceGrossYield: avgGross,
      avgPriceAfterTaxYield: avgNet,
      twrGross: twrGross,
      twrAfterTax: twrNet,
      distributions: distributionList,
      monthlyCloses: monthlyCloses,
      qualifies: true,
    );
  }

  int _barIndexAt(int divTs, List<int> bars) {
    if (bars.isEmpty) return -1;
    int idx = 0;
    for (int i = 0; i < bars.length; i++) {
      if (bars[i] <= divTs) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  double? _priceAt(
      int divTs, List<int> bars, List<dynamic> closes) {
    if (bars.isEmpty || closes.isEmpty) return null;
    int idx = 0;
    for (int i = 0; i < bars.length; i++) {
      if (bars[i] <= divTs) {
        idx = i;
      } else {
        break;
      }
    }
    final raw = idx < closes.length ? closes[idx] : null;
    if (raw is num) return raw.toDouble();
    for (int j = idx; j >= 0; j--) {
      final v = j < closes.length ? closes[j] : null;
      if (v is num) return v.toDouble();
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('iYield'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Calculate'),
              Tab(text: 'Distributions'),
              Tab(text: 'Prices'),
            ],
          ),
        ),
        body: SafeArea(
          child: TabBarView(
            children: [
              _buildCalculateTab(context),
              _DistributionsTab(result: _result),
              _PricesTab(result: _result),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCalculateTab(BuildContext context) {
    return SingleChildScrollView(
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
              _section(context, 'Simple TTM',
                  'sum(distributions) / current price'),
              _row('Gross yield', _pct(r.grossYield)),
              _row('After-tax yield', _pct(r.afterTaxYield)),
              _section(context, 'Compounded (DRIP)',
                  '∏(1 + d_t / P_t) − 1 using monthly closes'),
              _row('Gross yield', _pct(r.compoundedGrossYield)),
              _row('After-tax yield', _pct(r.compoundedAfterTaxYield)),
              _section(context, 'Average-price denominator',
                  'sum(distributions) / mean(monthly closes)'),
              _row('Gross yield', _pct(r.avgPriceGrossYield)),
              _row('After-tax yield', _pct(r.avgPriceAfterTaxYield)),
              _section(context, 'Total return (TWR)',
                  '∏((P_{t+1} + d_t) / P_t) − 1 — includes price change'),
              _row('Gross', _pct(r.twrGross)),
              _row('After-tax (dist. only)', _pct(r.twrAfterTax)),
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

  Widget _section(BuildContext context, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

String _fmtDate(DateTime d) {
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '${d.year}-$m-$day';
}

String _fmtMonth(DateTime d) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[d.month - 1]} ${d.year}';
}

class _DistributionsTab extends StatelessWidget {
  final YieldResult? result;
  const _DistributionsTab({required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result;
    if (r == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
              'Run Calculate to populate.',
              textAlign: TextAlign.center),
        ),
      );
    }
    if (r.distributions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '${r.ticker}: no distributions in the last 12 months.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final total = r.sumDistributions;
    final theme = Theme.of(context);
    final firstDate = r.distributions.last.date;
    final lastDate = r.distributions.first.date;
    final avg = total / r.distributions.length;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: r.distributions.length + 3,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.ticker, style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '${r.distributions.length} distributions • '
                  '${_fmtDate(firstDate)} → ${_fmtDate(lastDate)}',
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  'Total \$${total.toStringAsFixed(4)} • '
                  'avg \$${avg.toStringAsFixed(4)}',
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          );
        }
        if (i == 1) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Date',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w600)),
                Text('Amount',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
          );
        }
        if (i == r.distributions.length + 2) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Total (12mo)',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                Text('\$${total.toStringAsFixed(4)}',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
          );
        }
        final d = r.distributions[i - 2];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_fmtDate(d.date)),
              Text('\$${d.amount.toStringAsFixed(4)}'),
            ],
          ),
        );
      },
    );
  }
}

class _PricesTab extends StatelessWidget {
  final YieldResult? result;
  const _PricesTab({required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result;
    if (r == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Run Calculate to populate.',
              textAlign: TextAlign.center),
        ),
      );
    }
    final closes = [...r.monthlyCloses]
      ..sort((a, b) => b.monthStart.compareTo(a.monthStart));
    if (closes.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No monthly closes returned.',
              textAlign: TextAlign.center),
        ),
      );
    }
    final theme = Theme.of(context);
    final valid = closes
        .map((c) => c.close)
        .whereType<double>()
        .toList();
    final mean = valid.isEmpty
        ? 0
        : valid.reduce((a, b) => a + b) / valid.length;
    final hi = valid.isEmpty
        ? 0
        : valid.reduce((a, b) => a > b ? a : b);
    final lo = valid.isEmpty
        ? 0
        : valid.reduce((a, b) => a < b ? a : b);
    final last = closes.first.monthStart;
    final first = closes.last.monthStart;
    final pctChange = (valid.length >= 2)
        ? (valid.first - valid.last) / valid.last * 100
        : 0;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: closes.length + 2,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.ticker, style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '${closes.length} monthly closes • '
                  '${_fmtMonth(first)} → ${_fmtMonth(last)}',
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  'Current \$${r.currentPrice.toStringAsFixed(2)} • '
                  'mean \$${mean.toStringAsFixed(2)} • '
                  'range \$${lo.toStringAsFixed(2)}–\$${hi.toStringAsFixed(2)} • '
                  '12mo Δ ${pctChange >= 0 ? '+' : ''}'
                  '${pctChange.toStringAsFixed(2)}%',
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          );
        }
        if (i == 1) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Month',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w600)),
                Text('Close',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
          );
        }
        final c = closes[i - 2];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_fmtMonth(c.monthStart)),
              Text(c.close == null
                  ? '—'
                  : '\$${c.close!.toStringAsFixed(2)}'),
            ],
          ),
        );
      },
    );
  }
}
