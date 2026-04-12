# Wartości logiczne z deploy.conf / env (bash 4+)

truthy() {
    case "${1,,}" in
        true | 1 | yes | y | on | tak) return 0 ;;
        *) return 1 ;;
    esac
}

falsey() {
    case "${1,,}" in
        false | 0 | no) return 0 ;;
        *) return 1 ;;
    esac
}
