import NootyCore
import UIKit

/// Cartes de révision du bloc-notes : liste, édition et séance de révision.
final class FlashcardsViewController: UITableViewController {
    private weak var editor: NotebookViewController?
    private var cards: [Flashcard] { editor?.manifest.cards ?? [] }

    init(editor: NotebookViewController) {
        self.editor = editor
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("cards.title")
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.edit(nil) }),
            UIBarButtonItem(title: L("cards.generate"), image: UIImage(systemName: "sparkles"), primaryAction: UIAction { [weak self] _ in self?.generate() }),
        ]
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "card")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : max(1, cards.count)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? nil : L("cards.count", cards.count)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "card", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        if indexPath.section == 0 {
            let due = Leitner.dueCards(cards, now: nowMs()).count
            content.text = L("cards.review")
            content.secondaryText = L("cards.due", due)
            content.image = UIImage(systemName: "play.circle.fill")
            content.imageProperties.tintColor = Theme.accent
            cell.accessoryType = .disclosureIndicator
        } else if cards.isEmpty {
            content.text = L("cards.empty")
            content.textProperties.color = Theme.secondaryText
            cell.accessoryType = .none
        } else {
            let c = cards[indexPath.row]
            content.text = c.front
            content.secondaryText = c.back
            content.secondaryTextProperties.numberOfLines = 2
            content.prefersSideBySideTextAndSecondaryText = false
            cell.accessoryType = .none
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            let due = Leitner.dueCards(cards, now: nowMs())
            let deck = due.isEmpty ? cards.shuffled() : due
            guard !deck.isEmpty else { return }
            navigationController?.pushViewController(ReviewViewController(cards: deck) { [weak self] reviewed in
                self?.editor?.updateManifest { m in
                    for c in reviewed { if let i = m.cards.firstIndex(where: { $0.id == c.id }) { m.cards[i] = c } }
                }
                self?.tableView.reloadData()
            }, animated: true)
        } else if !cards.isEmpty {
            edit(cards[indexPath.row])
        }
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1, !cards.isEmpty else { return nil }
        let id = cards[indexPath.row].id
        return UISwipeActionsConfiguration(actions: [UIContextualAction(style: .destructive, title: L("common.delete")) { [weak self] _, _, done in
            self?.editor?.updateManifest { $0.cards.removeAll { $0.id == id } }
            self?.tableView.reloadData()
            done(true)
        }])
    }

    private func edit(_ card: Flashcard?) {
        let alert = UIAlertController(title: card == nil ? L("cards.new") : L("cards.edit"), message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = L("cards.front"); $0.text = card?.front }
        alert.addTextField { $0.placeholder = L("cards.back"); $0.text = card?.back }
        alert.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("common.save"), style: .default) { [weak self, weak alert] _ in
            let front = alert?.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let back = alert?.textFields?[1].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !front.isEmpty else { return }
            self?.editor?.updateManifest { m in
                if let card, let i = m.cards.firstIndex(where: { $0.id == card.id }) {
                    m.cards[i].front = front
                    m.cards[i].back = back
                } else {
                    m.cards.append(Flashcard(front: front, back: back))
                }
            }
            self?.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    /// Propose des cartes générées par l'IA à partir du bloc-notes ; elles restent modifiables.
    private func generate() {
        guard let editor else { return }
        let source = AIContext.build(editor: editor, scope: .notebook)
        AIConsent.confirm(from: self, scope: source.scopeDescription) { [weak self] in
            self?.navigationItem.prompt = L("ai.working")
            AIService.shared.flashcards(from: source.text) { result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.navigationItem.prompt = nil
                    switch result {
                    case let .success(pairs):
                        self.editor?.updateManifest { m in m.cards.append(contentsOf: pairs.map { Flashcard(front: $0.0, back: $0.1) }) }
                        self.tableView.reloadData()
                    case let .failure(error):
                        let alert = UIAlertController(title: L("common.error"), message: error.localizedDescription, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: L("common.ok"), style: .default))
                        self.present(alert, animated: true)
                    }
                }
            }
        }
    }
}

/// Séance de révision : on lit le recto, on retourne la carte, on indique si on savait.
final class ReviewViewController: UIViewController {
    private var queue: [Flashcard]
    private var reviewed: [Flashcard] = []
    private let onFinish: ([Flashcard]) -> Void
    private let card = UIButton(type: .system)
    private let progress = UILabel()
    private let answers = UIStackView()
    private var showingBack = false
    private let total: Int

    init(cards: [Flashcard], onFinish: @escaping ([Flashcard]) -> Void) {
        queue = cards
        total = cards.count
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("cards.review")
        view.backgroundColor = Theme.desk
        card.backgroundColor = Theme.panel
        card.layer.cornerRadius = 20
        card.layer.borderWidth = 1
        card.layer.borderColor = Theme.hairline.cgColor
        card.titleLabel?.numberOfLines = 0
        card.titleLabel?.textAlignment = .center
        card.titleLabel?.font = .preferredFont(forTextStyle: .title2)
        card.titleLabel?.adjustsFontForContentSizeCategory = true
        card.contentEdgeInsets = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        card.setTitleColor(Theme.text, for: .normal)
        card.addAction(UIAction { [weak self] _ in self?.flip() }, for: .touchUpInside)
        progress.font = .preferredFont(forTextStyle: .footnote)
        progress.textColor = Theme.secondaryText
        progress.textAlignment = .center
        let again = UIButton(configuration: .gray(), primaryAction: UIAction { [weak self] _ in self?.answer(knew: false) })
        again.setTitle(L("cards.again"), for: .normal)
        let knew = UIButton(configuration: .filled(), primaryAction: UIAction { [weak self] _ in self?.answer(knew: true) })
        knew.setTitle(L("cards.knew"), for: .normal)
        knew.tintColor = Theme.accent
        answers.addArrangedSubview(again)
        answers.addArrangedSubview(knew)
        answers.spacing = 16
        answers.distribution = .fillEqually
        for v in [card, progress, answers] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            progress.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            progress.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 16),
            card.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: answers.topAnchor, constant: -20),
            answers.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            answers.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            answers.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            answers.heightAnchor.constraint(equalToConstant: 50),
        ])
        show()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent { onFinish(reviewed) }
    }

    private func show() {
        guard let c = queue.first else {
            card.setTitle(L("cards.done", reviewed.count), for: .normal)
            answers.isHidden = true
            progress.text = nil
            return
        }
        showingBack = false
        card.setTitle(c.front, for: .normal)
        card.accessibilityHint = L("cards.flipHint")
        answers.isHidden = true
        progress.text = L("cards.progress", total - queue.count + 1, total)
    }

    private func flip() {
        guard let c = queue.first else { return }
        showingBack.toggle()
        UIView.transition(with: card, duration: 0.3, options: .transitionFlipFromRight) {
            self.card.setTitle(self.showingBack ? (c.back.isEmpty ? "—" : c.back) : c.front, for: .normal)
        }
        answers.isHidden = !showingBack
    }

    private func answer(knew: Bool) {
        guard !queue.isEmpty else { return }
        let c = Leitner.review(queue.removeFirst(), knew: knew, now: nowMs())
        reviewed.removeAll { $0.id == c.id }
        reviewed.append(c)
        // Une carte ratée revient en fin de séance.
        if !knew { queue.append(c) }
        show()
    }
}
