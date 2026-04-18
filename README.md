# Claude Usage Bar

Application menu bar macOS pour surveiller votre consommation Claude Max.

## Fonctionnalites

- Barre de progression dans la menu bar avec pourcentage d'utilisation
- Couleurs dynamiques : vert (<50%) → jaune (50-80%) → rouge (>80%)
- Details au clic : session 5h, limites hebdomadaires, Claude Design
- Rafraichissement automatique toutes les 5 minutes
- Stockage securise des credentials dans le Keychain

## Installation

### Option 1: Compiler avec Xcode

1. Ouvrir le dossier dans Xcode :
   ```bash
   cd ~/Developer/ClaudeUsageBar
   open Package.swift
   ```

2. Dans Xcode : Product → Build (Cmd+B)

3. Product → Run (Cmd+R)

### Option 2: Compiler en ligne de commande

```bash
cd ~/Developer/ClaudeUsageBar
swift build -c release
```

L'executable sera dans `.build/release/ClaudeUsageBar`

## Configuration

Au premier lancement, l'app ouvrira automatiquement la fenetre de configuration.

### Obtenir l'Organization ID

1. Aller sur https://claude.ai/settings/usage
2. Ouvrir DevTools (Cmd+Option+I)
3. Onglet Network → Filtrer par XHR
4. Rafraichir la page
5. Chercher la requete vers `/api/organizations/.../usage`
6. L'ID est dans l'URL : `8b711afd-6fda-44ef-8382-d45659a498a1`

### Obtenir le Cookie de Session

1. Dans la meme requete, onglet Headers
2. Copier la valeur complete du header `Cookie`

## Utilisation

- Clic sur l'icone : affiche les details d'utilisation
- Icone engrenage : ouvrir les parametres
- Icone X : quitter l'application

## Lancer au demarrage

1. Preferences Systeme → Utilisateurs et groupes
2. Onglet "Ouverture"
3. Ajouter ClaudeUsageBar

## Structure du projet

```
ClaudeUsageBar/
├── Package.swift
├── ClaudeUsageBar/
│   ├── Info.plist
│   └── Sources/
│       ├── ClaudeUsageBarApp.swift  # Point d'entree
│       ├── StatusBarController.swift # Controle menu bar
│       ├── PopoverView.swift         # Interface SwiftUI
│       ├── UsageData.swift           # Modeles de donnees
│       ├── ClaudeAPIService.swift    # Appels API
│       └── KeychainHelper.swift      # Stockage securise
```

## Compatibilite

- macOS 12.0+ (Monterey)
- Compatible Intel et Apple Silicon
