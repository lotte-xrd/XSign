import SwiftUI

/// Tokens do XSign. As cores vêm do Asset Catalog (Color Sets com valor claro e
/// escuro), para o tema seguir o sistema sem cor fixa no código.
extension Color {
    // Neutros
    static let paper       = Color("Paper")            // fundo da marca
    static let stoneBG     = Color("StoneBackground")  // fundo das telas
    static let surface     = Color("Surface")          // grupos, cards, barras
    static let fill        = Color("Fill")             // busca, segmentos, botão secundário
    static let hairline    = Color("Hairline")         // separadores
    static let graphite    = Color("Graphite")         // texto, botões, ícones ativos
    static let onGraphite   = Color("OnGraphite")       // texto sobre grafite
    static let lead        = Color("Lead")             // texto secundário
    static let ash         = Color("Ash")              // abas inativas, setas

    // Status
    static let moss        = Color("Moss")   // válido / concluído
    static let ochre       = Color("Ochre")  // expira em breve
    static let brick       = Color("Brick")  // revogado / erro / excluir
}

enum Spacing {
    static let screen: CGFloat = 16
    static let group: CGFloat = 24
    static let row: CGFloat = 12
    static let tight: CGFloat = 8
}

enum Radius {
    static let group: CGFloat = 12
    static let button: CGFloat = 14
    static let sheet: CGFloat = 16
    static let icon: CGFloat = 0.224 // fração do lado (squircle)
}

extension View {
    /// Padding de tela padrão.
    func screenPadding() -> some View { padding(.horizontal, Spacing.screen) }
}
