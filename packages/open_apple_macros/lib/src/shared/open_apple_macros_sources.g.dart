// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'open_apple_macros_sources.dart';

// **************************************************************************
// StrEmbeddingGenerator
// **************************************************************************

const _$sourcePackageResolved = r'''
{
  "originHash" : "5daf3e40d748a8ca80767897a0ddc96c2dbd4268e6d8ab6026f44348802e132c",
  "pins" : [
    {
      "identity" : "swift-syntax",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/swiftlang/swift-syntax.git",
      "state" : {
        "revision" : "050f1a346fbbac0ca2cfb15a95274f7bd1cf0ccf",
        "version" : "604.0.0"
      }
    }
  ],
  "version" : 3
}

''';

const _$sourcePackageSwift = r'''
// swift-tools-version: 6.1

import PackageDescription

let macroTargets: [Target] = [
    .target(
        name: "FoundationModelsMacros",
        dependencies: [
            "OpenAppleMacrosBase",
            .product(name: "SwiftDiagnostics", package: "swift-syntax"),
        ],
    ),
    .target(
        name: "PreviewsMacros",
        dependencies: ["OpenAppleMacrosBase"],
    ),
    .target(
        name: "SwiftUIMacros",
        dependencies: [
            "OpenAppleMacrosBase",
            .product(name: "SwiftDiagnostics", package: "swift-syntax"),
        ],
    ),
]

let macroDependencies = macroTargets.map {
    Target.Dependency.byName(name: $0.name)
}

let package = Package(
    name: "OpenAppleMacros",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .executable(
            name: "OpenAppleMacrosServer",
            targets: ["OpenAppleMacrosServer"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
    ],
    targets: [
        .target(
            name: "OpenAppleMacrosBase",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "OpenAppleMacrosServer",
            dependencies: [
                "OpenAppleMacrosBase",
                .product(name: "_SwiftCompilerPluginMessageHandling", package: "swift-syntax"),
            ] + macroDependencies
        )
    ] + macroTargets
)

''';

const _$sourceFoundationModelsMacrosGenerableMacroSwift = r'''
import Foundation
import OpenAppleMacrosBase
import SwiftDiagnostics

struct GenerableMacro: MemberMacro, ExtensionMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        if explicitlyConformsToGenerable(declaration) {
            context.diagnose(Diagnostic(
                node: node,
                message: FoundationModelsDiagnostic("Type already conforms to 'Generable'. Remove the '@Generable' macro or delete the existing conformance.")
            ))
            return []
        }
        let options = GenerableOptions(node)
        if let structure = declaration.as(StructDeclSyntax.self) {
            return structMembers(structure, options: options)
        }
        if let enumeration = declaration.as(EnumDeclSyntax.self) {
            return enumMembers(enumeration, options: options, node: node, in: context)
        }
        context.diagnose(Diagnostic(
            node: node,
            message: FoundationModelsDiagnostic("'@Generable' can only be used on structs and enums.")
        ))
        return []
    }

    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard !explicitlyConformsToGenerable(declaration) else { return [] }
        let access = accessPrefix(of: declaration)
        let attributes = availabilityPrefix(of: declaration)
        if let structure = declaration.as(StructDeclSyntax.self) {
            let properties = storedProperties(of: structure)
            let assignments = renderConditional(properties) {
                "self.\($0.name.text) = try content.value(forProperty: \(swiftStringLiteral($0.keyName)))"
            }
            let initializerBody = assignments.isEmpty ? "" : "\n\(indent(assignments, by: 4))\n"
            let source = """
            \(attributes)extension \(type.trimmed): nonisolated FoundationModels.Generable {
            \(indent("nonisolated \(access)init(_ content: FoundationModels.GeneratedContent) throws {\(initializerBody)}", by: 4))
            }
            """
            return [
                try ExtensionDeclSyntax("\(raw: source)")
            ]
        }
        if let enumeration = declaration.as(EnumDeclSyntax.self) {
            let cases = enumCases(of: enumeration)
            let flatCases = flatElements(cases)
            guard !flatCases.isEmpty else { return [] }
            let body: String
            if flatCases.contains(where: { !$0.values.isEmpty }) {
                body = enumContentInitializer(cases: cases, partial: false)
            } else if isRawValueEnum(enumeration) {
                body = rawEnumInitializer()
            } else {
                body = plainEnumInitializer(cases: cases)
            }
            let source = """
            \(attributes)extension \(type.trimmed): nonisolated FoundationModels.Generable {
            \(indent("nonisolated \(access)init(_ content: FoundationModels.GeneratedContent) throws {\n\(indent(body, by: 4))\n}", by: 4))
            }
            """
            return [try ExtensionDeclSyntax("\(raw: source)")]
        }
        return []
    }
}

private struct GenerableOptions {
    var name: ExprSyntax?
    var description: ExprSyntax?
    var explicitNil: ExprSyntax?

    init(_ attribute: AttributeSyntax) {
        guard case .argumentList(let arguments) = attribute.arguments else { return }
        for argument in arguments {
            switch argument.label?.text {
            case "name": name = argument.expression
            case "description": description = argument.expression
            case "representNilExplicitlyInGeneratedContent": explicitNil = argument.expression
            default: break
            }
        }
    }
}

private struct StoredProperty {
    var name: TokenSyntax
    var keyName: String
    var type: TypeSyntax
    var guide: GuideOptions?
}

private struct GuideOptions {
    var description: ExprSyntax?
    var guides: [ExprSyntax]
}

private enum ConditionalElement<Element> {
    case element(Element)
    case ifConfig([ConditionalClause<Element>])
}

private struct ConditionalClause<Element> {
    var poundKeyword: String
    var condition: String?
    var elements: [ConditionalElement<Element>]
}

private func conditionalElements<Element>(
    in members: MemberBlockItemListSyntax,
    transform: (DeclSyntax) -> [Element]
) -> [ConditionalElement<Element>] {
    members.flatMap { member -> [ConditionalElement<Element>] in
        if let ifConfig = member.decl.as(IfConfigDeclSyntax.self) {
            let clauses = ifConfig.clauses.map { clause -> ConditionalClause<Element> in
                let declarations = clause.elements?.as(MemberBlockItemListSyntax.self)
                return ConditionalClause(
                    poundKeyword: clause.poundKeyword.trimmed.description,
                    condition: clause.condition?.trimmed.description,
                    elements: declarations.map {
                        conditionalElements(in: $0, transform: transform)
                    } ?? []
                )
            }
            return [.ifConfig(clauses)]
        }
        return transform(member.decl).map(ConditionalElement.element)
    }
}

private func flatElements<Element>(_ elements: [ConditionalElement<Element>]) -> [Element] {
    elements.flatMap { element in
        switch element {
        case .element(let value):
            return [value]
        case .ifConfig(let clauses):
            return clauses.flatMap { flatElements($0.elements) }
        }
    }
}

private func containsIfConfig<Element>(_ elements: [ConditionalElement<Element>]) -> Bool {
    elements.contains {
        if case .ifConfig = $0 { return true }
        return false
    }
}

private func renderConditional<Element>(
    _ elements: [ConditionalElement<Element>],
    transform: (Element) -> String
) -> String {
    elements.map { element in
        switch element {
        case .element(let value):
            return transform(value)
        case .ifConfig(let clauses):
            let body = clauses.map { clause in
                let directive = clause.condition.map {
                    "\(clause.poundKeyword) \($0)"
                } ?? clause.poundKeyword
                let elements = renderConditional(clause.elements, transform: transform)
                return elements.isEmpty ? directive : "\(directive)\n\(elements)"
            }.joined(separator: "\n")
            return "\(body)\n#endif"
        }
    }.joined(separator: "\n")
}

private func conditionalDeclarations<Element>(
    _ elements: [ConditionalElement<Element>],
    transform: (Element) -> DeclSyntax
) -> [DeclSyntax] {
    elements.map { element in
        switch element {
        case .element(let value):
            return transform(value)
        case .ifConfig:
            return parseDeclaration(renderConditional([element]) {
                transform($0).trimmed.description
            })
        }
    }
}

private func renderConditionalWithBlankAfterIfConfig<Element>(
    _ elements: [ConditionalElement<Element>],
    transform: (Element) -> String
) -> String {
    var result = ""
    for (index, element) in elements.enumerated() {
        if index > 0 {
            if case .ifConfig = elements[index - 1] {
                result += "\n\n"
            } else {
                result += "\n"
            }
        }
        result += renderConditional([element], transform: transform)
    }
    return result
}

private func storedProperties(of declaration: some DeclGroupSyntax) -> [ConditionalElement<StoredProperty>] {
    conditionalElements(in: declaration.memberBlock.members) { member -> [StoredProperty] in
        guard let variable = member.as(VariableDeclSyntax.self),
              !variable.modifiers.contains(where: {
                  $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
              }) else { return [] }
        return variable.bindings.compactMap { binding in
            guard binding.accessorBlock == nil,
                  let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
                  let type = binding.typeAnnotation?.type else { return nil }
            return StoredProperty(
                name: name.trimmed,
                keyName: unbackticked(name.text),
                type: type.trimmed,
                guide: guideOptions(in: variable.attributes)
            )
        }
    }
}

private func guideOptions(in attributes: AttributeListSyntax) -> GuideOptions? {
    guard let attribute = attributes.compactMap({ $0.as(AttributeSyntax.self) }).first(where: {
        $0.attributeName.trimmed.description == "Guide"
    }) else { return nil }
    var result = GuideOptions(description: nil, guides: [])
    guard case .argumentList(let arguments) = attribute.arguments else { return result }
    for argument in arguments {
        if argument.label?.text == "description" {
            result.description = argument.expression
        } else {
            result.guides.append(argument.expression)
        }
    }
    return result
}

private func structMembers(_ declaration: StructDeclSyntax, options: GenerableOptions) -> [DeclSyntax] {
    let properties = storedProperties(of: declaration)
    let access = accessPrefix(of: declaration)
    let schema: DeclSyntax
    if containsIfConfig(properties) {
        schema = conditionalSchemaDeclaration(
            access: access,
            options: options,
            properties: properties,
            typeExpression: options.name == nil ? "Self.self" : nil
        )
    } else {
        schema = schemaDeclaration(
            access: access,
            options: options,
            properties: flatElements(properties),
            typeExpression: options.name == nil ? "Self.self" : nil
        )
    }
    let generatedContent = generatedContentDeclaration(access: access, properties: properties, explicitNil: options.explicitNil)
    let explicitlyIdentifiable = declaration.inheritanceClause?.inheritedTypes.contains(where: {
        $0.type.trimmed.description.split(separator: ".").last == "Identifiable"
    }) ?? false
    if declaresPartiallyGenerated(in: declaration.memberBlock.members) {
        return [schema, generatedContent]
    }
    let partial = partialStructDeclaration(
        access: access,
        properties: properties,
        synthesizeID: !explicitlyIdentifiable
            && !flatElements(properties).contains(where: { $0.keyName == "id" })
    )
    return [schema, generatedContent, partial]
}

private func declaresPartiallyGenerated(in members: MemberBlockItemListSyntax) -> Bool {
    members.contains { member in
        let declaration = member.decl
        if declaration.as(StructDeclSyntax.self)?.name.text == "PartiallyGenerated"
            || declaration.as(EnumDeclSyntax.self)?.name.text == "PartiallyGenerated"
            || declaration.as(ClassDeclSyntax.self)?.name.text == "PartiallyGenerated"
            || declaration.as(ActorDeclSyntax.self)?.name.text == "PartiallyGenerated"
            || declaration.as(TypeAliasDeclSyntax.self)?.name.text == "PartiallyGenerated" {
            return true
        }
        if let ifConfig = declaration.as(IfConfigDeclSyntax.self) {
            return ifConfig.clauses.contains { clause in
                clause.elements?.as(MemberBlockItemListSyntax.self).map(declaresPartiallyGenerated(in:)) ?? false
            }
        }
        return false
    }
}

private func schemaDeclaration(
    access: String,
    options: GenerableOptions,
    properties: [StoredProperty],
    typeExpression: String?
) -> DeclSyntax {
    var arguments: [String] = []
    if let name = options.name {
        arguments.append("name: \(name.trimmed)")
    } else if let typeExpression {
        arguments.append("type: \(typeExpression)")
    }
    if let description = options.description {
        arguments.append("description: \(description.trimmed)")
    }
    if let explicitNil = options.explicitNil {
        arguments.append("representNilExplicitlyInGeneratedContent: \(explicitNil.trimmed)")
    }
    let propertyLines = properties.map(propertySchema).joined(separator: ",\n")
    arguments.append("properties: [\n\(indent(propertyLines, by: 4))\n]")
    let argumentsText = arguments.map { indent($0, by: 8) }.joined(separator: ",\n")
    return """
    nonisolated \(raw: access)static var generationSchema: FoundationModels.GenerationSchema {
        FoundationModels.GenerationSchema(
    \(raw: argumentsText)
        )
    }
    """
}

private func conditionalSchemaDeclaration(
    access: String,
    options: GenerableOptions,
    properties: [ConditionalElement<StoredProperty>],
    typeExpression: String?
) -> DeclSyntax {
    let additions = renderConditional(properties) {
        "properties.append(\(propertySchema($0)))"
    }
    var arguments: [String] = []
    if let name = options.name {
        arguments.append("name: \(name.trimmed)")
    } else if let typeExpression {
        arguments.append("type: \(typeExpression)")
    }
    if let description = options.description {
        arguments.append("description: \(description.trimmed)")
    }
    if let explicitNil = options.explicitNil {
        arguments.append("representNilExplicitlyInGeneratedContent: \(explicitNil.trimmed)")
    }
    arguments.append("properties: properties")
    let argumentsText = arguments.map { indent($0, by: 8) }.joined(separator: ",\n")
    return parseDeclaration(
        "nonisolated \(access)static var generationSchema: FoundationModels.GenerationSchema {\n" +
        "    var properties = [FoundationModels.GenerationSchema.Property]()\n" +
        indent(additions, by: 4) + "\n" +
        "    return FoundationModels.GenerationSchema(\n" + argumentsText + "\n    )\n" +
        "}"
    )
}

private func propertySchema(_ property: StoredProperty) -> String {
    var arguments = ["name: \(swiftStringLiteral(property.keyName))"]
    if let description = property.guide?.description {
        arguments.append("description: \(description.trimmed)")
    }
    arguments.append("type: \(property.type.trimmed).self")
    if let guides = property.guide?.guides, !guides.isEmpty {
        arguments.append("guides: [\(guides.map { $0.trimmed.description }.joined(separator: ", "))]")
    }
    return "FoundationModels.GenerationSchema.Property(\(arguments.joined(separator: ", ")))"
}

private func generatedContentDeclaration(
    access: String,
    properties: [ConditionalElement<StoredProperty>],
    explicitNil: ExprSyntax?
) -> DeclSyntax {
    let additions = renderConditional(properties) {
        "addProperty(name: \(swiftStringLiteral($0.keyName)), value: self.\($0.name.text))"
    }
    let explicitNilExpression = explicitNil?.trimmed.description ?? "false"
    var lines = [
        "nonisolated \(access)var generatedContent: GeneratedContent {",
        "    let explicitNil = \(explicitNilExpression)",
        "    var properties = [(name: String, value: any ConvertibleToGeneratedContent)]()",
    ]
    if !additions.isEmpty {
        lines.append(indent(additions, by: 4))
    }
    lines += [
        "    return GeneratedContent(",
        "        properties: properties,",
        "        uniquingKeysWith: { _, second in",
        "            second",
        "        }",
        "    )",
        "    func addProperty(name: String, value: some Generable) {",
        "      properties.append((name: name, value: value))",
        "    }",
        "    func addProperty(name: String, value: (some Generable)?) {",
        "      if explicitNil || value != nil {",
        "        properties.append((name: name, value: value))",
        "      }",
        "    }",
        "}",
    ]
    return parseDeclaration(lines.joined(separator: "\n"))
}

private func partialStructDeclaration(
    access: String,
    properties: [ConditionalElement<StoredProperty>],
    synthesizeID: Bool
) -> DeclSyntax {
    let conformance = synthesizeID
        ? "Identifiable, nonisolated FoundationModels.ConvertibleFromGeneratedContent"
        : "nonisolated FoundationModels.ConvertibleFromGeneratedContent"
    var declarations: [String] = []
    var assignments: [String] = []
    if synthesizeID {
        declarations.append("\(access)var id: GenerationID")
        assignments.append("self.id = content.id ?? GenerationID()")
    }
    let propertyDeclarations = renderConditional(properties) {
        "\(access)var \($0.name.text): \($0.type.trimmed).PartiallyGenerated?"
    }
    let propertyAssignments = renderConditional(properties) {
        "self.\($0.name.text) = try content.value(forProperty: \(swiftStringLiteral($0.keyName)))"
    }
    if !propertyDeclarations.isEmpty { declarations.append(propertyDeclarations) }
    if !propertyAssignments.isEmpty { assignments.append(propertyAssignments) }
    return """
    nonisolated \(raw: access)struct PartiallyGenerated: \(raw: conformance) {
        \(raw: declarations.joined(separator: "\n"))
        nonisolated \(raw: access)init(_ content: FoundationModels.GeneratedContent) throws {
            \(raw: assignments.joined(separator: "\n"))
        }
    }
    """
}

private struct EnumCaseInfo {
    var name: TokenSyntax
    var rawValue: ExprSyntax?
    var values: [EnumValueInfo]
}

private struct EnumValueInfo {
    var label: TokenSyntax?
    var propertyName: String
    var keyName: String
    var type: TypeSyntax
}

private func enumCases(of declaration: EnumDeclSyntax) -> [ConditionalElement<EnumCaseInfo>] {
    conditionalElements(in: declaration.memberBlock.members) { member -> [EnumCaseInfo] in
        guard let caseDecl = member.as(EnumCaseDeclSyntax.self) else { return [] }
        return caseDecl.elements.map { element in
            let parameters = Array(element.parameterClause?.parameters ?? [])
            var nextUnlabeled = 0
            let values = parameters.map { parameter -> EnumValueInfo in
                let label = parameter.firstName?.tokenKind == .wildcard ? nil : parameter.firstName
                let propertyName: String
                if let internalName = parameter.secondName {
                    propertyName = internalName.text
                } else if let label {
                    propertyName = label.text
                } else if nextUnlabeled == 0 {
                    propertyName = "value"
                    nextUnlabeled += 1
                } else {
                    propertyName = "value\(nextUnlabeled)"
                    nextUnlabeled += 1
                }
                return EnumValueInfo(
                    label: label,
                    propertyName: propertyName,
                    keyName: unbackticked(propertyName),
                    type: parameter.type.trimmed
                )
            }
            return EnumCaseInfo(name: element.name.trimmed, rawValue: element.rawValue?.value, values: values)
        }
    }
}

private func enumMembers(
    _ declaration: EnumDeclSyntax,
    options: GenerableOptions,
    node: AttributeSyntax,
    in context: some MacroExpansionContext
) -> [DeclSyntax] {
    let cases = enumCases(of: declaration)
    let flatCases = flatElements(cases)
    guard !flatCases.isEmpty else {
        context.diagnose(Diagnostic(
            node: node,
            message: FoundationModelsDiagnostic("Generable enums must have at least one case.")
        ))
        return []
    }
    let access = accessPrefix(of: declaration)
    if flatCases.contains(where: { !$0.values.isEmpty }) {
        return payloadEnumMembers(
            cases: cases,
            access: access,
            options: options,
            includePartial: !declaresPartiallyGenerated(in: declaration.memberBlock.members)
        )
    }
    return plainEnumMembers(declaration, cases: cases, access: access, options: options)
}

private func plainEnumMembers(
    _ declaration: EnumDeclSyntax,
    cases: [ConditionalElement<EnumCaseInfo>],
    access: String,
    options: GenerableOptions
) -> [DeclSyntax] {
    let raw = isRawValueEnum(declaration)
    let flatCases = flatElements(cases)
    let values = flatCases.map {
        raw ? "\($0.name.text).rawValue" : swiftStringLiteral($0.name.text)
    }.joined(separator: ", ")
    var arguments = [options.name.map { "name: \($0.trimmed)" } ?? "type: Self.self"]
    if let description = options.description {
        arguments.append("description: \(description.trimmed)")
    }
    let schema: DeclSyntax
    if containsIfConfig(cases) {
        let additions = renderConditional(cases) {
            let value = raw ? "\($0.name.text).rawValue" : swiftStringLiteral($0.name.text)
            return "properties.append(\(value))"
        }
        arguments.append("anyOf: properties")
        schema = parseDeclaration(
            "nonisolated \(access)static var generationSchema: FoundationModels.GenerationSchema {\n" +
            "    var properties = [String]()\n" + indent(additions, by: 4) + "\n" +
            "    return FoundationModels.GenerationSchema(\(arguments.joined(separator: ", ")))\n" +
            "}"
        )
    } else {
        arguments.append("anyOf: [\(values)]")
        schema = parseDeclaration(
            "nonisolated \(access)static var generationSchema: FoundationModels.GenerationSchema {\n" +
            "    FoundationModels.GenerationSchema(\(arguments.joined(separator: ", ")))\n" +
            "}"
        )
    }
    let content: DeclSyntax
    if raw {
        content = parseDeclaration(
            "nonisolated \(access)var generatedContent: GeneratedContent {\n" +
            "    rawValue.generatedContent\n" +
            "}"
        )
    } else {
        let bodyIndent = containsIfConfig(cases) ? 0 : 4
        let branches = renderConditionalWithBlankAfterIfConfig(cases) {
            "case .\($0.name.text):\n" + indent(
                "\(swiftStringLiteral($0.name.text)).generatedContent",
                by: bodyIndent
            )
        }
        content = parseDeclaration(
            "nonisolated \(access)var generatedContent: GeneratedContent {\n" +
            "    switch self {\n" + indent(branches, by: 4) + "\n    }\n" +
            "}"
        )
    }
    return [schema, content]
}

private func payloadEnumMembers(
    cases: [ConditionalElement<EnumCaseInfo>],
    access: String,
    options: GenerableOptions,
    includePartial: Bool
) -> [DeclSyntax] {
    let partialCases = renderConditional(cases) { enumCaseDeclaration($0, partial: true) }
    let partialInit = enumContentInitializer(cases: cases, partial: true)
    let partial = parseDeclaration(
        "nonisolated \(access)enum PartiallyGenerated: nonisolated FoundationModels.ConvertibleFromGeneratedContent {\n" +
        indent(partialCases, by: 4) + "\n" +
        "    nonisolated \(access)init(_ content: FoundationModels.GeneratedContent) throws {\n" +
        indent(partialInit, by: 8) + "\n" +
        "    }\n" +
        "}"
    )
    var schemaArguments = [options.name.map { "name: \($0.trimmed)" } ?? "type: Self.self"]
    if let description = options.description {
        schemaArguments.append("description: \(description.trimmed)")
    }
    let schema: DeclSyntax
    if containsIfConfig(cases) {
        let additions = renderConditional(cases) {
            "properties.append(Discriminated\(uppercasingFirst($0.name.text)).self)"
        }
        schemaArguments.append("anyOf: properties")
        schema = parseDeclaration(
            "nonisolated \(access)static var generationSchema: FoundationModels.GenerationSchema {\n" +
            "    var properties = [any Generable.Type]()\n" + indent(additions, by: 4) + "\n" +
            "    return FoundationModels.GenerationSchema(\(schemaArguments.joined(separator: ", ")))\n" +
            "}"
        )
    } else {
        let types = flatElements(cases).map {
            "Discriminated\(uppercasingFirst($0.name.text)).self"
        }.joined(separator: ",\n")
        schemaArguments.append("anyOf: [\n\(indent(types, by: 4))\n]")
        let schemaText = schemaArguments.map { indent($0, by: 8) }.joined(separator: ",\n")
        schema = parseDeclaration(
            "nonisolated \(access)static var generationSchema: FoundationModels.GenerationSchema {\n" +
            "    FoundationModels.GenerationSchema(\n" + schemaText + "\n    )\n" +
            "}"
        )
    }
    let discriminators = conditionalDeclarations(cases) { discriminatorDeclaration($0, options: options) }
    let content = enumGeneratedContent(cases: cases, access: access)
    return (includePartial ? [partial] : []) + [schema] + discriminators + [content]
}

private func discriminatorDeclaration(_ enumCase: EnumCaseInfo, options: GenerableOptions) -> DeclSyntax {
    let name = "Discriminated\(uppercasingFirst(enumCase.name.text))"
    let isBacktickedCase = enumCase.name.text.first == "`" && enumCase.name.text.last == "`"
    let declarationName = isBacktickedCase ? "Discriminated" : name
    let conformance = isBacktickedCase ? "" : ": nonisolated FoundationModels.Generable"
    var properties = [StoredProperty(name: .identifier("type"), keyName: "type", type: "String", guide: GuideOptions(
        description: nil,
        guides: [ExprSyntax(".constant(\(raw: swiftStringLiteral(enumCase.name.text)))")]
    ))]
    properties += enumCase.values.map {
        StoredProperty(name: .identifier($0.propertyName), keyName: $0.keyName, type: $0.type, guide: nil)
    }
    let declarations = properties.map { property -> String in
        if property.name.text == "type" {
            return "@Guide(.constant(\(swiftStringLiteral(enumCase.name.text))))\nlet type: String"
        }
        return "let \(property.name.text): \(property.type.trimmed)"
    }.joined(separator: "\n")
    let assignments = properties.map {
        "self.\($0.name.text) = try content.value(forProperty: \(swiftStringLiteral($0.keyName)))"
    }.joined(separator: "\n")
    let schema = schemaDeclaration(access: "", options: GenerableOptionsForDiscriminator(options), properties: properties, typeExpression: "Self.self")
    let generated = generatedContentDeclaration(
        access: "",
        properties: properties.map(ConditionalElement.element),
        explicitNil: options.explicitNil
    )
    let initializer = "nonisolated init(_ content: FoundationModels.GeneratedContent) throws {\n\(indent(assignments, by: 4))\n}"
    let source = "private nonisolated struct \(declarationName)\(conformance) {\n" +
        indent(declarations, by: 4) + "\n" +
        indent(initializer, by: 4) + "\n" +
        indent(schema.trimmed.description, by: 4) + "\n" +
        indent(generated.trimmed.description, by: 4) + "\n" +
        "}"
    return parseDeclaration(source)
}

private func GenerableOptionsForDiscriminator(_ options: GenerableOptions) -> GenerableOptions {
    var result = options
    result.name = nil
    return result
}

private func enumCaseDeclaration(_ enumCase: EnumCaseInfo, partial: Bool) -> String {
    guard !enumCase.values.isEmpty else { return "case \(enumCase.name.text)" }
    let parameters = enumCase.values.map { value in
        let type = "\(value.type.trimmed)\(partial ? ".PartiallyGenerated?" : "")"
        if let label = value.label {
            return "\(label.text): \(type)"
        }
        return type
    }.joined(separator: ", ")
    return "case \(enumCase.name.text)(\(parameters))"
}

private func enumContentInitializer(cases: [ConditionalElement<EnumCaseInfo>], partial: Bool) -> String {
    let branches = renderConditional(cases) { enumCase -> String in
        let name = enumCase.name.text
        guard !enumCase.values.isEmpty else {
            return "case \(swiftStringLiteral(name)):\n    self = .\(name)"
        }
        let arguments = enumCase.values.map { value in
            let expression = "try content.value(forProperty: \(swiftStringLiteral(value.keyName)))"
            return value.label.map { "\($0.text): \(expression)" } ?? expression
        }
        let assignment: String
        if arguments.count == 1 {
            assignment = "self = .\(name)(\(arguments[0]))"
        } else {
            assignment = "self = .\(name)(\n\(indent(arguments.joined(separator: ",\n"), by: 4))\n)"
        }
        return "case \(swiftStringLiteral(name)):\n" + indent(assignment, by: 4)
    }
    return "let type: String = try content.value(forProperty: \"type\")\n" +
        "switch type {\n" + branches + "\n" +
        "default:\n" + indent(unexpectedValueThrow(variable: "type", adjective: "type"), by: 4) + "\n" +
        "}"
}

private func enumGeneratedContent(cases: [ConditionalElement<EnumCaseInfo>], access: String) -> DeclSyntax {
    let bodyIndent = containsIfConfig(cases) ? 0 : 4
    let branches = renderConditional(cases) { enumCase -> String in
        let bindings = enumCase.values.map { "let \($0.propertyName)" }.joined(separator: ", ")
        let pattern = ".\(enumCase.name.text)\(bindings.isEmpty ? "" : "(\(bindings))")"
        let entries = (["\"type\": \(swiftStringLiteral(enumCase.name.text))"] + enumCase.values.map {
            "\(swiftStringLiteral($0.keyName)): \($0.propertyName)"
        }).joined(separator: ",\n")
        let bodyEntries = enumCase.values.isEmpty ? entries + ",\n" : entries
        return "case \(pattern):\n" +
            indent(
                "GeneratedContent(\n" +
                "    properties: [\n" + indent(bodyEntries, by: 8) + "\n" +
                "    ]\n" +
                ")",
                by: bodyIndent
            )
    }
    return parseDeclaration(
        "nonisolated \(access)var generatedContent: GeneratedContent {\n" +
        "    switch self {\n" + indent(branches, by: 4) + "\n" +
        "    }\n" +
        "}"
    )
}

private func plainEnumInitializer(cases: [ConditionalElement<EnumCaseInfo>]) -> String {
    let branches = renderConditional(cases) {
        "case \(swiftStringLiteral($0.name.text)):\n    self = .\($0.name.text)"
    }
    return "let rawValue = try content.value(String.self)\n" +
        "switch rawValue {\n" + branches + "\n" +
        "default:\n" + indent(unexpectedValueThrow(variable: "rawValue", adjective: "value"), by: 4) + "\n" +
        "}"
}

private func rawEnumInitializer() -> String {
    "let rawValue = try content.value(String.self)\n" +
        "if let value = Self(rawValue: rawValue) {\n" +
        "    self = value\n" +
        "} else {\n" + indent(unexpectedValueThrow(variable: "rawValue", adjective: "rawValue"), by: 4) + "\n" +
        "}"
}

private func unexpectedValueThrow(variable: String, adjective: String) -> String {
    """
    if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
        throw FoundationModels.GeneratedContent.ParsingError(rawContent: content.jsonString, debugDescription: "Unexpected \(adjective) \\\"\\(\(variable))\\\" for \\(Self.self)")
    } else {
        throw FoundationModels.LanguageModelSession.GenerationError.decodingFailure(FoundationModels.LanguageModelSession.GenerationError.Context(debugDescription: "Unexpected \(adjective) \\\"\\(\(variable))\\\" for \\(Self.self)"))
    }
    """
}

private func isRawValueEnum(_ declaration: EnumDeclSyntax) -> Bool {
    guard let first = declaration.inheritanceClause?.inheritedTypes.first?.type.trimmed.description else {
        return false
    }
    let name = first.split(separator: ".").last.map(String.init) ?? first
    return name == "String"
}

private func accessPrefix(of declaration: some DeclGroupSyntax) -> String {
    if declaration.modifiers.contains(where: { $0.name.tokenKind == .keyword(.public) }) {
        return "public "
    }
    if declaration.modifiers.contains(where: { $0.name.tokenKind == .keyword(.package) }) {
        return "package "
    }
    return ""
}

private func explicitlyConformsToGenerable(_ declaration: some DeclGroupSyntax) -> Bool {
    declaration.inheritanceClause?.inheritedTypes.contains(where: {
        $0.type.trimmed.description.split(separator: ".").last == "Generable"
    }) ?? false
}

private func availabilityPrefix(of declaration: some DeclGroupSyntax) -> String {
    declaration.attributes.compactMap { $0.as(AttributeSyntax.self) }.filter {
        $0.attributeName.trimmed.description.split(separator: ".").last == "available"
    }.map { "\($0.trimmed)\n" }.joined()
}

private func swiftStringLiteral(_ value: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    return String(decoding: data, as: UTF8.self)
}

private func uppercasingFirst(_ value: String) -> String {
    guard let first = value.first else { return value }
    return first.uppercased() + value.dropFirst()
}

private func unbackticked(_ value: String) -> String {
    guard value.count >= 2, value.first == "`", value.last == "`" else { return value }
    return String(value.dropFirst().dropLast())
}

private func indent(_ text: String, by spaces: Int) -> String {
    let prefix = String(repeating: " ", count: spaces)
    return text.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n")
}

private func parseDeclaration(_ source: String) -> DeclSyntax {
    "\(raw: source)"
}

''';

const _$sourceFoundationModelsMacrosGuideMacroSwift = r'''
import OpenAppleMacrosBase
import SwiftDiagnostics

struct GuideMacro: PeerMacro, AccessorMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        validate(node, declaration: declaration, in: context)
        return []
    }

    static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        return []
    }

    private static func validate(
        _ node: AttributeSyntax,
        declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              !variable.modifiers.contains(where: {
                  $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
              }),
              variable.bindings.allSatisfy({ $0.accessorBlock == nil }) else {
            context.diagnose(Diagnostic(
                node: node,
                message: FoundationModelsDiagnostic("'@Guide' can only be used with a stored property.")
            ))
            return
        }
    }
}

struct FoundationModelsDiagnostic: DiagnosticMessage, FixItMessage {
    let message: String
    let severity: DiagnosticSeverity

    init(_ message: String, severity: DiagnosticSeverity = .error) {
        self.message = message
        self.severity = severity
    }

    var diagnosticID: MessageID {
        MessageID(domain: "FoundationModelsMacros", id: message)
    }
    var fixItID: MessageID { diagnosticID }
}

''';

const _$sourceFoundationModelsMacrosMacrosSwift = r'''
import OpenAppleMacrosBase

package var all: [Macro.Type] {
    [
        GenerableMacro.self,
        GuideMacro.self,
        SessionPropertyEntryMacro.self,
        SessionPropertyEntryDefaultValueMacro.self,
    ]
}


''';

const _$sourceFoundationModelsMacrosSessionPropertyEntryMacroSwift = r'''
import OpenAppleMacrosBase
import SwiftDiagnostics

struct SessionPropertyEntryMacro: PeerMacro, AccessorMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let extensionType = context.lexicalContext.first?.as(ExtensionDeclSyntax.self)?.extendedType.trimmed.description
        guard extensionType == "SessionPropertyValues"
                || extensionType == "FoundationModels.SessionPropertyValues" else {
            context.diagnose(Diagnostic(
                node: node,
                message: FoundationModelsDiagnostic("'@SessionPropertyEntry' macro can only attach to var declarations inside extensions of SessionPropertyValues"),
                highlights: [Syntax(declaration)]
            ))
            return []
        }
        guard let property = sessionProperty(
            from: declaration,
            node: node,
            requireDefaultValue: true,
            in: context
        ), let initialValue = property.initialValue else { return [] }
        let type = property.type.map { ": \($0.trimmed)" } ?? ""
        return [
            """
            private struct __Key_\(property.name): FoundationModels.SessionPropertyKey {
                @FoundationModels.__SessionPropertyEntryDefaultValue
                static var defaultValue\(raw: type) = \(initialValue.trimmed)
            }
            """
        ]
    }

    static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let property = sessionProperty(
            from: declaration,
            node: node,
            requireDefaultValue: false,
            in: context
        ) else { return [] }
        return [
            """
            get {
                self[__Key_\(property.name).self]
            }
            """,
            """
            set {
                self[__Key_\(property.name).self] = newValue
            }
            """,
            """
            _modify {
                yield &self[__Key_\(property.name).self]
            }
            """,
        ]
    }
}

struct SessionPropertyEntryDefaultValueMacro: AccessorMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              let value = variable.bindings.first?.initializer?.value else {
            return []
        }
        return [
            """
            get {
                \(value.trimmed)
            }
            """
        ]
    }
}

private struct SessionProperty {
    var name: TokenSyntax
    var type: TypeSyntax?
    var initialValue: ExprSyntax?
}

private func sessionProperty(
    from declaration: some DeclSyntaxProtocol,
    node: AttributeSyntax,
    requireDefaultValue: Bool,
    in context: some MacroExpansionContext
) -> SessionProperty? {
    guard let variable = declaration.as(VariableDeclSyntax.self) else { return nil }
    if variable.bindingSpecifier.tokenKind == .keyword(.let) {
        let token = variable.bindingSpecifier
        context.diagnose(Diagnostic(
            node: node,
            message: FoundationModelsDiagnostic("'@SessionPropertyEntry' can only be applied to a 'var' declaration"),
            highlights: [Syntax(variable)],
            fixIts: [FixIt(
                message: FoundationModelsDiagnostic("Replace 'let' with 'var'"),
                changes: [.replace(
                    oldNode: Syntax(token),
                    newNode: Syntax(TokenSyntax.keyword(
                        .var,
                        leadingTrivia: token.leadingTrivia,
                        trailingTrivia: token.trailingTrivia
                    ))
                )]
            )]
        ))
        return nil
    }
    if !requireDefaultValue, let modifier = variable.modifiers.first(where: {
        $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
    }) {
        context.diagnose(Diagnostic(
            node: modifier.name,
            message: FoundationModelsDiagnostic("'@SessionPropertyEntry' cannot be applied to a static member"),
            fixIts: [FixIt(
                message: FoundationModelsDiagnostic("Remove 'static'"),
                changes: [.replaceText(
                    range: modifier.position..<modifier.endPosition,
                    with: "",
                    in: Syntax(variable)
                )]
            )]
        ))
        return nil
    }
    guard variable.bindings.count == 1,
          let binding = variable.bindings.first else {
        context.diagnose(Diagnostic(
            node: node,
            message: FoundationModelsDiagnostic("'@SessionPropertyEntry' can only be applied to a 'var' declaration with a simple name"),
            highlights: [Syntax(variable)]
        ))
        return nil
    }
    guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier else {
        context.diagnose(Diagnostic(
            node: binding,
            message: FoundationModelsDiagnostic("Expected an identifier for the property")
        ))
        return nil
    }
    if !requireDefaultValue, let accessorBlock = binding.accessorBlock {
        context.diagnose(Diagnostic(
            node: accessorBlock,
            message: FoundationModelsDiagnostic("'@SessionPropertyEntry' can only be applied to a stored property"),
            fixIts: [FixIt(
                message: FoundationModelsDiagnostic("Remove '@SessionPropertyEntry'"),
                changes: [.replaceText(
                    range: node.position..<node.endPosition,
                    with: "",
                    in: Syntax(variable)
                )]
            )]
        ))
        return nil
    }
    if requireDefaultValue, binding.initializer == nil {
        let position = binding.endPositionBeforeTrailingTrivia
        context.diagnose(Diagnostic(
            node: name,
            message: FoundationModelsDiagnostic("Property missing a default value"),
            highlights: [Syntax(binding)],
            fixIts: [FixIt(
                message: FoundationModelsDiagnostic("Provide default value"),
                changes: [.replaceText(
                    range: position..<position,
                    with: " = <#default value#>",
                    in: Syntax(binding)
                )]
            )]
        ))
        return nil
    }
    return SessionProperty(
        name: name.trimmed,
        type: binding.typeAnnotation?.type,
        initialValue: binding.initializer?.value
    )
}

''';

const _$sourceOpenAppleMacrosBaseMacroErrorSwift = r'''
public struct MacroError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

''';

const _$sourceOpenAppleMacrosBaseOpenAppleMacrosBaseSwift = r'''
@_exported import SwiftSyntax
@_exported import SwiftSyntaxMacros

''';

const _$sourceOpenAppleMacrosServerModulesSwift = r'''
import OpenAppleMacrosBase
import FoundationModelsMacros
import PreviewsMacros
import SwiftUIMacros

var allMacros: [[any Macro.Type]] { [
    FoundationModelsMacros.all,
    PreviewsMacros.all,
    SwiftUIMacros.all,
] }

''';

const _$sourceOpenAppleMacrosServerOpenAppleMacrosSwift = r'''
@_spi(PluginMessage) import SwiftCompilerPluginMessageHandling
import OpenAppleMacrosBase

@main enum Server {
    static func main() throws {
        let connection = try StandardIOMessageConnection()
        let listener = CompilerPluginMessageListener(
            connection: connection,
            messageHandler: PluginProviderMessageHandler(provider: Provider())
        )
        try listener.main()
    }
}

private struct Provider: PluginProvider {
    private let macrosByName: [String: Macro.Type]
    private let modules: Set<String>

    init() {
        let macros = allMacros.flatMap { $0 }
        macrosByName = Dictionary(macros.map { (String(reflecting: $0), $0) }) { $1 }
        modules = Set(macrosByName.keys.compactMap { $0.split(separator: ".", maxSplits: 1).first }.map { String($0) })
    }

    var features: [PluginFeature] {
        [.loadPluginLibrary]
    }

    func loadPluginLibrary(libraryPath: String, moduleName: String) throws {
        guard modules.contains(moduleName) else {
            throw MacroError("OpenAppleMacros: Could not find macros for module '\(moduleName)'")
        }
    }

    func resolveMacro(moduleName: String, typeName: String) throws -> Macro.Type {
        let key = "\(moduleName).\(typeName)"
        guard let macro = macrosByName[key] else {
            throw MacroError("OpenAppleMacros: Could not find macro '\(typeName)' in module '\(moduleName)'")
        }
        return macro
    }
}

''';

const _$sourcePreviewsMacrosMacrosSwift = r'''
import OpenAppleMacrosBase

package var all: [Macro.Type] {
    [
        SwiftUIView.self,
        KitViewMacro.self,
        Common.self,
        Previewable.self,
    ]
}

struct SwiftUIView: DeclarationMacro {
    static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        return []
    }
}

struct KitViewMacro: DeclarationMacro {
    static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        return []
    }
}

struct Common: DeclarationMacro {
    static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        return []
    }
}

struct Previewable: PeerMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        return []
    }
}

''';

const _$sourceSwiftUIMacrosAnimatableMacroSwift = r'''
import Foundation
import OpenAppleMacrosBase
import SwiftDiagnostics

struct AnimatableValuesMacro: MemberMacro, ExtensionMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        if declaration.hasAnimatableData {
            context.diagnose(Diagnostic(node: node, message: AnimatableDiagnostic(
                "'@Animatable' macro has no effect on types with 'animatableData' property.",
                severity: .warning
            ), notes: [Note(node: Syntax(node), message: AnimatableNote("Remove '@Animatable'"))]))
            return []
        }

        let properties = declaration.animatableProperties(in: context)
        guard !properties.isEmpty else {
            context.diagnose(Diagnostic(node: node, message: AnimatableDiagnostic(
                "'@Animatable' macro has no effect; it can only attach to types with animatable properties."
            ), notes: [Note(node: Syntax(node), message: AnimatableNote("Remove '@Animatable'"))]))
            return []
        }

        let name = context.makeUniqueName("_animatableData").text
        let file = context.location(of: node, at: .afterLeadingTrivia, filePathMode: .filePath)?.file.description ?? "\"\""
        let payload: [String: Any] = [
            "animatableDataName": name,
            "fileName": file,
            "varDecls": properties.map { ["name": $0.name, "line": $0.line] },
        ]
        let json = String(data: try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]), encoding: .utf8)!

        return [
            """
            #_SwiftUIAnimatableDataProperty(animatableMacroContext: #"\(raw: json)"#, kind: SwiftUICore._animatableMacroKind())

            nonisolated var animatableData: some VectorArithmetic {
                get {
                    \(raw: name)
                }
                set {
                    nonisolated func inferType<T, U>(_ t: T) -> U {
                        t as! U
                    }
                    \(raw: name) = inferType(newValue)
                }
            }
            """
        ]
    }

    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard !declaration.hasAnimatableData else { return [] }
        return [try ExtensionDeclSyntax("extension \(type.trimmed): nonisolated SwiftUICore.Animatable {}")]
    }
}

struct AnimatableIgnoredMacro: AccessorMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        let enclosingType = context.lexicalContext.first { $0.asProtocol(DeclGroupSyntax.self) != nil }?
            .asProtocol(DeclGroupSyntax.self)
        let insideAnimatable = enclosingType?.attributes.contains {
            $0.as(AttributeSyntax.self)?.macroName == "Animatable"
        } ?? false
        if !insideAnimatable {
            context.diagnose(Diagnostic(node: declaration, message: AnimatableDiagnostic(
                "'@AnimatableIgnored' macro has no effect outside of an '@Animatable' type.",
                severity: .warning
            ), highlights: [Syntax(declaration)], notes: [Note(node: Syntax(declaration), message: AnimatableNote("Remove '@AnimatableIgnored'"))]))
        }
        return []
    }
}

struct AnimatableValuesDataPropertyMacro: DeclarationMacro {
    static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try dataPropertyExpansion(of: node, pair: false)
    }
}

struct AnimatablePairDataPropertyMacro: DeclarationMacro {
    static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try dataPropertyExpansion(of: node, pair: true)
    }
}

private func dataPropertyExpansion(
    of node: some FreestandingMacroExpansionSyntax,
    pair: Bool
) throws -> [DeclSyntax] {
        guard let string = node.arguments.first?.expression.as(StringLiteralExprSyntax.self),
              case .stringSegment(let segment) = string.segments.first,
              let data = segment.content.text.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = payload["animatableDataName"] as? String,
              let file = payload["fileName"] as? String,
              let properties = payload["varDecls"] as? [[String: String]] else {
            return []
        }
        let lines = properties.compactMap { property -> String? in
            guard let name = property["name"], let line = property["line"] else { return nil }
            return """
                #sourceLocation(file: \(file), line: \(line))
                let \(name) = #_SwiftUIAnimatableProperty(Self[_animatableType: \\.\(name)])
                #sourceLocation()
                """
        }.joined(separator: "\n")
        let values = properties.compactMap { $0["name"] }
        guard !values.isEmpty else { return [] }
        let result: String
        if pair {
            result = pairExpression(values, indent: 4, zeroLeaves: true)
        } else {
            result = "SwiftUICore.AnimatableValues(\(values.joined(separator: ", ")))"
        }
        let attribute = pair ? "_AnimatablePairData" : "_AnimatableData"
        return [
            """
            @SwiftUICore.\(raw: attribute)
            private nonisolated var \(raw: name) = {
                \(raw: lines)
                return \(raw: result)
            }()
            """
        ]
}

struct AnimatableValuesDataMacro: AccessorMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        dataAccessorExpansion(of: declaration, pair: false)
    }
}

struct AnimatablePairDataMacro: AccessorMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        dataAccessorExpansion(of: declaration, pair: true)
    }
}

private func dataAccessorExpansion(
    of declaration: some DeclSyntaxProtocol,
    pair: Bool
) -> [AccessorDeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              let call = variable.bindings.first?.initializer?.value.as(FunctionCallExprSyntax.self),
              let closure = call.calledExpression.as(ClosureExprSyntax.self) else { return [] }
        let names = closure.statements.compactMap {
            $0.item.as(VariableDeclSyntax.self)?.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
        }
        guard !names.isEmpty else { return [] }
        let getters = names.map { "let \($0) = self[_animatableValue: \\.\($0)]" }.joined(separator: "\n")
        let setters = names.enumerated().map { index, name in
            let value = pair ? pairPath(index, count: names.count) :
                "newValue.value\(names.count == 1 ? "" : ".\(index)")"
            return "self[_animatableValue: \\.\(name)] = \(value)"
        }.joined(separator: "\n")
        let result = pair ? pairExpression(names, indent: 4, zeroLeaves: false) :
            "SwiftUICore.AnimatableValues(\(names.joined(separator: ", ")))"
        return [
            """
            get {
                \(raw: getters)
                return \(raw: result)
            }
            """,
            """
            set {
                \(raw: setters)
            }
            """,
        ]
}

private func pairExpression(
    _ values: [String],
    indent: Int,
    zeroLeaves: Bool,
    nested: Bool = false
) -> String {
    if values.count == 1 {
        return values[0] + (zeroLeaves ? ".zero" : "")
    }
    let middle = values.count / 2
    let zeroChild = zeroLeaves && values.count > 2
    let nestedIndent = indent + (nested ? 0 : 4)
    let left = pairExpression(Array(values[..<middle]), indent: nestedIndent, zeroLeaves: zeroChild, nested: true)
    let right = pairExpression(Array(values[middle...]), indent: nestedIndent, zeroLeaves: zeroChild, nested: true)
    let padding = String(repeating: " ", count: indent)
    let childPadding = nested ? padding : padding + "    "
    return "SwiftUICore.AnimatablePair(\n\(childPadding)\(left),\n\(childPadding)\(right)\n\(padding))"
}

private func pairPath(_ index: Int, count: Int) -> String {
    guard count > 1 else { return "newValue" }
    let middle = count / 2
    if index < middle {
        return "newValue.first" + String(pairPath(index, count: middle).dropFirst("newValue".count))
    } else {
        return "newValue.second" + String(pairPath(index - middle, count: count - middle).dropFirst("newValue".count))
    }
}

struct AnimatablePropertyMacro: ExpressionMacro {
    static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        node.arguments.first?.expression ?? "()"
    }
}

struct InvalidAnimatablePropertyMacro: ExpressionMacro {
    static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        context.diagnose(Diagnostic(node: node, message: AnimatableDiagnostic(
            "Cannot automatically synthesize 'animatableData'."
        ), notes: [
            Note(node: Syntax(node), message: AnimatableNote("Mark this property with '@AnimatableIgnored'.")),
            Note(node: Syntax(node), message: AnimatableNote("Conform the type of this property to 'Animatable' or 'VectorArithmetic'.")),
        ]))
        return "EmptyAnimatableData.self"
    }
}

private struct AnimatableProperty {
    let name: String
    let line: String
}

private extension DeclGroupSyntax {
    var hasAnimatableData: Bool {
        memberBlock.members.contains { member in
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { return false }
            return variable.bindings.contains {
                $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "animatableData"
            }
        }
    }

    func animatableProperties(in context: some MacroExpansionContext) -> [AnimatableProperty] {
        memberBlock.members.flatMap { member -> [AnimatableProperty] in
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  variable.bindingSpecifier.tokenKind == .keyword(.var),
                  !variable.attributes.contains(where: {
                      $0.as(AttributeSyntax.self)?.macroName == "AnimatableIgnored"
                  }) else { return [] }
            return variable.bindings.compactMap { binding in
                guard binding.isStored,
                      let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
                      let location = context.location(of: binding, at: .afterLeadingTrivia, filePathMode: .filePath) else {
                    return nil
                }
                return AnimatableProperty(name: identifier.text, line: location.line.description)
            }
        }
    }
}

private extension PatternBindingSyntax {
    var isStored: Bool {
        guard let accessorBlock else { return true }
        guard case .accessors(let accessors) = accessorBlock.accessors else { return false }
        return accessors.allSatisfy {
            $0.accessorSpecifier.tokenKind == .keyword(.willSet) ||
            $0.accessorSpecifier.tokenKind == .keyword(.didSet)
        }
    }
}

private struct AnimatableDiagnostic: DiagnosticMessage {
    let message: String
    let severity: DiagnosticSeverity

    init(_ message: String, severity: DiagnosticSeverity = .error) {
        self.message = message
        self.severity = severity
    }

    var diagnosticID: MessageID { MessageID(domain: "SwiftUIMacros", id: message) }
}

private struct AnimatableNote: NoteMessage {
    let message: String

    init(_ message: String) { self.message = message }
    var noteID: MessageID { MessageID(domain: "SwiftUIMacros", id: message) }
}

private extension AttributeSyntax {
    var macroName: String? {
        attributeName.trimmed.description.split(separator: ".").last.map(String.init)
    }
}

''';

const _$sourceSwiftUIMacrosEntryMacroSwift = r'''
import OpenAppleMacrosBase
import SwiftDiagnostics

struct EntryMacro: PeerMacro, AccessorMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let ext = context.lexicalContext.first?.as(ExtensionDeclSyntax.self)

        let kind: EntryKind
        switch ext.map({ "\($0.extendedType.trimmed)" }) {
        case "EnvironmentValues", "SwiftUI.EnvironmentValues", "SwiftUICore.EnvironmentValues":
            kind = .environmentValues
        case "Transaction", "SwiftUI.Transaction", "SwiftUICore.Transaction":
            kind = .transaction
        case "ContainerValues", "SwiftUI.ContainerValues", "SwiftUICore.ContainerValues":
            kind = .containerValues
        case "FocusedValues", "SwiftUI.FocusedValues":
            kind = .focusedValues
        default:
            context.diagnose(Diagnostic(
                node: node,
                message: EntryDiagnostic("'@Entry' macro can only attach to var declarations inside extensions of EnvironmentValues, ContainerValues, Transaction, or FocusedValues"),
                highlights: [Syntax(declaration)]
            ))
            return []
        }

        guard let varDecl = declaration.as(VariableDeclSyntax.self) else {
            return []
        }
        if varDecl.bindingSpecifier.tokenKind == .keyword(.let) {
            diagnoseLet(node: node, declaration: varDecl, in: context)
            return []
        }
        guard varDecl.bindings.count == 1,
              let binding = varDecl.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
            context.diagnose(Diagnostic(
                node: node,
                message: EntryDiagnostic("'@Entry' can only be applied to a 'var' declaration with a simple name"),
                highlights: [Syntax(varDecl)]
            ))
            return []
        }

        if kind == .focusedValues {
            guard let optionalType = binding.typeAnnotation?.type.as(OptionalTypeSyntax.self) else {
                throw MacroError("'@Entry' on 'FocusedValues' requires an optional type")
            }
            return [
                """
                private struct __Key_\(pattern.identifier.trimmed): \(kind.keyType) {
                    typealias Value = \(optionalType.wrappedType.trimmed)
                }
                """
            ]
        }

        guard let initializer = binding.initializer else {
            let position = binding.endPositionBeforeTrailingTrivia
            context.diagnose(Diagnostic(
                node: pattern,
                message: EntryDiagnostic("Property missing a default value"),
                highlights: [Syntax(binding)],
                fixIts: [FixIt(
                    message: EntryDiagnostic("Provide default value"),
                    changes: [.replaceText(range: position..<position, with: " = <#default value#>", in: Syntax(binding))]
                )]
            ))
            return []
        }

        let typeAnnotation = binding.typeAnnotation.map { ": \($0.type.trimmed)" } ?? ""
        return [
            """
            private struct __Key_\(pattern.identifier.trimmed): \(kind.keyType) {
                @SwiftUICore.__EntryDefaultValue
                static var defaultValue\(raw: typeAnnotation) = \(initializer.value.trimmed)
            }
            """
        ]
    }

    static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let varDecl = declaration.as(VariableDeclSyntax.self),
              varDecl.bindings.count == 1,
              let binding = varDecl.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
            return []
        }
        if varDecl.bindingSpecifier.tokenKind == .keyword(.let) {
            diagnoseLet(node: node, declaration: varDecl, in: context)
            return []
        }
        return [
            "get { self[__Key_\(pattern.identifier.trimmed).self] }",
            "set { self[__Key_\(pattern.identifier.trimmed).self] = newValue }",
            "_modify { yield &self[__Key_\(pattern.identifier.trimmed).self] }",
        ]
    }
}

private func diagnoseLet(
    node: AttributeSyntax,
    declaration: VariableDeclSyntax,
    in context: some MacroExpansionContext
) {
    let token = declaration.bindingSpecifier
    context.diagnose(Diagnostic(
        node: node,
        message: EntryDiagnostic("'@Entry' can only be applied to a 'var' declaration"),
        highlights: [Syntax(declaration)],
        fixIts: [FixIt(
            message: EntryDiagnostic("Replace 'let' with 'var'"),
            changes: [.replace(
                oldNode: Syntax(token),
                newNode: Syntax(TokenSyntax.keyword(
                    .var,
                    leadingTrivia: token.leadingTrivia,
                    trailingTrivia: token.trailingTrivia
                ))
            )]
        )]
    ))
}

private struct EntryDiagnostic: DiagnosticMessage, FixItMessage {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var diagnosticID: MessageID { MessageID(domain: "SwiftUIMacros", id: message) }
    var fixItID: MessageID { diagnosticID }
    var severity: DiagnosticSeverity { .error }
}

struct EntryDefaultValueMacro: AccessorMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let varDecl = declaration.as(VariableDeclSyntax.self),
              varDecl.bindings.count == 1,
              let initializer = varDecl.bindings.first?.initializer else {
            throw MacroError("'@__EntryDefaultValue' requires an initialized variable")
        }
        return ["get { \(initializer.value.trimmed) }"]
    }
}

private enum EntryKind {
    case environmentValues
    case transaction
    case containerValues
    case focusedValues

    var keyType: TypeSyntax {
        switch self {
        case .environmentValues:
            return "SwiftUICore.EnvironmentKey"
        case .transaction:
            return "SwiftUICore.TransactionKey"
        case .containerValues:
            return "SwiftUICore.ContainerValueKey"
        case .focusedValues:
            return "SwiftUI.FocusedValueKey"
        }
    }
}

''';

const _$sourceSwiftUIMacrosMacrosSwift = r'''
import OpenAppleMacrosBase

package var all: [Macro.Type] {
    [
        AnimatableValuesMacro.self,
        AnimatableIgnoredMacro.self,
        AnimatableValuesDataPropertyMacro.self,
        AnimatableValuesDataMacro.self,
        AnimatablePairDataPropertyMacro.self,
        AnimatablePairDataMacro.self,
        AnimatablePropertyMacro.self,
        InvalidAnimatablePropertyMacro.self,
        EntryMacro.self,
        EntryDefaultValueMacro.self,
        StateMacro.self,
        ProjectedValueMacro.self,
        StateProjectedValueMacro.self,
        StatePropertyWrapperStorageMacro.self,
        StateInitialStoredValueMacro.self,
    ]
}

''';

const _$sourceSwiftUIMacrosStateMacroSwift = r'''
import Foundation
import OpenAppleMacrosBase

struct StateMacro: PeerMacro, AccessorMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              variable.bindings.count == 1,
              let binding = variable.bindings.first,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier else {
            return []
        }

        let name = identifier.trimmed.text
        let type = binding.typeAnnotation?.type.trimmed.description
        let isPrivate = variable.modifiers.contains { $0.name.tokenKind == .keyword(.private) }
        let projectedModifier = variable.modifiers.first.map { "\($0.name.trimmed) " } ?? ""
        let explicitValue = binding.initializer?.value.trimmed.description ?? node.stateValueArgument
        let value = explicitValue
            ?? (binding.typeAnnotation?.type.as(OptionalTypeSyntax.self) != nil ? "nil" : nil)

        guard let value else {
            guard let type else { return [] }
            return [
                "private var _\(raw: name): SwiftUICore.State<\(raw: type)>",
                """
                \(raw: projectedModifier)var $\(raw: name): SwiftUICore.Binding<\(raw: type)> {
                    _\(raw: name).projectedValue
                }
                """,
            ]
        }

        let stateType = type.map { "<\($0)>" } ?? ""
        let state = "SwiftUICore.State\(stateType)(initialValue: \(value))"

        if !isPrivate {
            return [
                "private var _\(raw: name) = \(raw: state)",
                """
                @SwiftUICore._PropertyWrapperProjectedValue
                \(raw: projectedModifier)var $\(raw: name) = \(raw: state).projectedValue
                """,
            ]
        }

        // Private state uses lazy backing storage and forwards initialization through helper macros.
        let initialStoredName = context.makeUniqueName("_initialStoredValue_").text
        let initialStoredNameEncoded = Data(initialStoredName.utf8).base64EncodedString()
        let storage: String
        let initialStoredValue: String
        let initialStoredGetter: String
        if let type {
            storage = "SwiftUICore.State._makeStorage(({ let value: \(type) = \(value)\nreturn value }))"
            initialStoredValue = "SwiftUICore.State._makeStorage(initialValue: { let x: \(type) = \(value)\nreturn x }())"
            initialStoredGetter = explicitValue == nil ? initialStoredValue : storage
        } else {
            storage = "SwiftUICore.State._makeStorage({ \(value) })"
            initialStoredValue = "SwiftUICore.State._makeStorage(initialValue: \(value))"
            initialStoredGetter = storage
        }
        // The helper macro receives the getter expression as base64 to preserve its source text.
        let initialStoredValueEncoded = Data(initialStoredGetter.utf8).base64EncodedString()

        return [
            "private var __\(raw: name) = \(raw: storage)",
            "@SwiftUICore._StatePropertyWrapperStorage(initialValue: \"\(raw: initialStoredNameEncoded)\")\nprivate var _\(raw: name): SwiftUICore.State<_>! = SwiftUICore._stateNil(of: {\n        \(raw: state)\n    })",
            """
            @SwiftUICore._StateProjectedValue
            private var $\(raw: name) = \(raw: state).projectedValue
            """,
            """
            @SwiftUICore._StateInitialStoredValue("\(raw: initialStoredValueEncoded)")
            private static var \(raw: initialStoredName) = (\(raw: initialStoredValue))
            """,
        ]
    }

    static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              variable.bindings.count == 1,
              let binding = variable.bindings.first,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier else {
            return []
        }

        let name = identifier.trimmed.text
        let isPrivate = variable.modifiers.contains { $0.name.tokenKind == .keyword(.private) }
        let hasExplicitValue = binding.initializer != nil || node.stateValueArgument != nil
        let hasValue = hasExplicitValue || binding.typeAnnotation?.type.as(OptionalTypeSyntax.self) != nil
        let storage = isPrivate && hasValue ? "__\(name)" : "_\(name)"
        var accessors: [AccessorDeclSyntax] = []
        if !isPrivate || !hasExplicitValue {
            accessors.append(
                """
                @storageRestrictions(initializes: \(raw: storage))
                init(initialValue) {
                    \(raw: storage) = SwiftUICore.State\(raw: isPrivate && hasValue ? "._makeStorage" : "")(initialValue: initialValue)
                }
                """
            )
        }
        accessors.append("get { \(raw: storage).wrappedValue }")
        accessors.append("nonmutating set { \(raw: storage).wrappedValue = newValue }")
        return accessors
    }
}

struct ProjectedValueMacro: AccessorMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let name = statePropertyName(declaration), name.hasPrefix("$") else { return [] }
        let wrappedName = String(name.dropFirst())
        return ["get { _\(raw: wrappedName).projectedValue }"]
    }
}

struct StateProjectedValueMacro: AccessorMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let name = statePropertyName(declaration), name.hasPrefix("$") else { return [] }
        let wrappedName = String(name.dropFirst())
        return ["get { __\(raw: wrappedName).projectedValue }"]
    }
}

struct StatePropertyWrapperStorageMacro: AccessorMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let name = statePropertyName(declaration),
              let encodedName = node.stateStringArgument,
              let nameData = Data(base64Encoded: encodedName),
              let initialStoredName = String(data: nameData, encoding: .utf8) else {
            return []
        }
        let storage = "__\(name.dropFirst())"
        return [
            """
            @storageRestrictions(initializes: \(raw: storage))
            init(initialValue) {
                if initialValue == nil {
                    \(raw: storage) = Self.\(raw: initialStoredName)
                } else {
                    \(raw: storage) = SwiftUICore.State._makeStorage(initialValue: initialValue.wrappedValue)
                }
            }
            """,
            "get { SwiftUICore.State(initialValue: \(raw: storage).wrappedValue) }",
            """
            set {
                if newValue != nil {
                    \(raw: storage) = SwiftUICore.State._makeStorage(initialValue: newValue.wrappedValue)
                }
            }
            """,
        ]
    }
}

struct StateInitialStoredValueMacro: AccessorMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let encoded = node.stateStringArgument,
              let data = Data(base64Encoded: encoded),
              let expression = String(data: data, encoding: .utf8) else {
            return []
        }
        return ["get { \(raw: expression) }"]
    }
}

private func statePropertyName(_ declaration: some DeclSyntaxProtocol) -> String? {
    guard let variable = declaration.as(VariableDeclSyntax.self),
          let identifier = variable.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier else {
        return nil
    }
    return identifier.trimmed.text
}

private extension AttributeSyntax {
    var stateValueArgument: String? {
        guard case .argumentList(let arguments) = arguments,
              let argument = arguments.first,
              let label = argument.label?.text,
              label == "initialValue" || label == "wrappedValue" else {
            return nil
        }
        return argument.expression.trimmed.description
    }

    var stateStringArgument: String? {
        guard case .argumentList(let arguments) = arguments,
              let string = arguments.first?.expression.as(StringLiteralExprSyntax.self),
              string.segments.count == 1,
              case .stringSegment(let segment) = string.segments.first else {
            return nil
        }
        return segment.content.text
    }
}

''';
